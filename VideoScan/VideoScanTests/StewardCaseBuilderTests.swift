// StewardCaseBuilderTests.swift
// The content steward's case builder and skip memory (trial UI, 2026-10-03;
// design §5.6 of docs/design/analyze_knowledge_and_storage_actions_2026-10-02.md).
//
// Five-dimension coverage (CLAUDE.md checklist):
//   Logic     — each card type (Reclaim per drive, Reclaim per set, Same
//               footage, Probably not worth keeping), queue order, the
//               words (freshness, button states, keeper reason, log line),
//               skip → stays away → comes back on a material change →
//               Bring back.
//   Scale     — 100k records, 2k duplicate sets, 3k footage groups, 20k
//               junk rows, 40 people for the event guess: explicit budget.
//   Isolation — the skip memory and the Catalog door run against their own
//               UserDefaults suite; a poisoned value never hides a case and
//               never crashes.
//   Sensor    — StewardSensorTests.swift (source-level).
// Media matrix: N/A — catalog metadata only, no media is opened.
//
// The two §5.6 rules (proof = the Delete planner's; exclusions) are in
// StewardRulesTests.swift. The event guess is in StewardEventGuessTests.swift.
//
// Suites: StewardCaseBuilderLogicTests · StewardWordsTests ·
//         StewardSkipStoreTests · StewardScaleTests

import Foundation
import Testing
@testable import VideoScan

private let GB: Int64 = 1_000_000_000
private let mounted: Set<String> = ["/", "/Volumes/SanDisk", "/Volumes/LaCie", "/Volumes/X9"]
private let volumes = [
    AnalyzeVolumeFact(root: "/Volumes/SanDisk", isReachable: true, isRetired: false),
    AnalyzeVolumeFact(root: "/Volumes/LaCie", isReachable: true, isRetired: false),
    AnalyzeVolumeFact(root: "/Volumes/X9", isReachable: true, isRetired: false),
    AnalyzeVolumeFact(root: "/Volumes/Gone", isReachable: false, isRetired: false),
]

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return c
}

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) ?? Date(timeIntervalSince1970: 0)
}

private func build(_ inputs: [StewardInput], crossMode: Bool = false,
                   people: [StewardEventGuess.Person] = []) -> StewardQueue {
    StewardCaseBuilder.build(inputs: inputs, volumes: volumes, mountedRoots: mounted,
                             alsoCleanUpWorkingCopies: crossMode, people: people, calendar: utc)
}

private func keeper(_ path: String, _ g: UUID, bytes: Int64 = GB) -> StewardInput {
    StewardInput(fullPath: path, sizeBytes: bytes, isKeeper: true, duplicateGroupID: g, hasUsableDigest: true)
}

private func extra(_ path: String, _ g: UUID, bytes: Int64 = GB,
                   protection: StewardProtection = .none) -> StewardInput {
    StewardInput(fullPath: path, sizeBytes: bytes, isExtraCopy: true, duplicateGroupID: g, protection: protection)
}

private func clip(_ path: String, footage g: UUID, strength: Int = 1, rank: Int = 0, original: UUID? = nil,
                  best: Date? = nil, precise: Date? = nil, evidence: [String] = []) -> StewardInput {
    StewardInput(fullPath: path, sizeBytes: GB, footageGroupID: g, footageStrength: strength, footageRank: rank,
                 footageRoleLabel: rank == 0 ? "likely original" : "copy", footageLikelyOriginalID: original,
                 footageEvidence: evidence, bestDate: best ?? precise, dayPreciseDate: precise)
}

private func junk(_ path: String, score: Int = 5, reasons: [String] = ["Very short (2.1s)"],
                  undecided: Bool = true, inTriage: Bool = true,
                  protection: StewardProtection = .none) -> StewardInput {
    StewardInput(fullPath: path, sizeBytes: 1_000_000, protection: protection, junkScore: score,
                 junkReasonKey: StewardCaseBuilder.junkReasonKey(reasons), isUndecided: undecided,
                 inTriageTable: inTriage)
}

// MARK: - Logic

@Suite("Steward — the cases built from what the catalog already knows")
struct StewardCaseBuilderLogicTests {

    // Reclaim space

    @Test func aDriveWithDuplicateCopiesGetsADriveCardWithTheCalculatorsNumbers() throws {
        let g = UUID()
        let inputs = [keeper("/Volumes/SanDisk/a/keep.mov", g),
                      extra("/Volumes/SanDisk/b/copy1.mov", g, bytes: 2 * GB),
                      extra("/Volumes/SanDisk/c/copy2.mov", g, bytes: 3 * GB)]
        let q = build(inputs)
        let drive = try #require(q.cases.first { $0.kind == .reclaimDrive })
        // The same arithmetic the Storage tab shows.
        let estimate = ReclaimableCalculator.compute(
            inputs: inputs.map { ReclaimableInput(fullPath: $0.fullPath, sizeBytes: $0.sizeBytes, isExtraCopy: $0.isExtraCopy,
                                                  isKeeper: $0.isKeeper, groupID: $0.duplicateGroupID,
                                                  hasUsableDigest: $0.hasUsableDigest) },
            volumeRoot: "/Volumes/SanDisk", mountedRoots: mounted, alsoCleanUpWorkingCopies: false)
        #expect(drive.id == "drive:/Volumes/SanDisk")
        #expect(drive.facts == StewardFacts(bytes: estimate.bytes, count: estimate.copies))
        #expect(drive.estimate?.copies == 2 && drive.estimate?.bytes == 5 * GB)
        #expect(drive.title == "SanDisk: \(ByteCountFormatter.string(fromByteCount: 5 * GB, countStyle: .file)) in 2 duplicate copies")
        #expect(drive.driveRoot == "/Volumes/SanDisk" && drive.driveConnected)
        #expect(Set(drive.recordIDs) == Set(inputs.dropFirst().map(\.id)), "Show these in the Catalog lists the copies, not the keeper")
    }

    @Test func aSetOfCopiesGetsACardThatNamesTheKeepersDriveAndWhatComesBack() throws {
        let g = UUID()
        let k = keeper("/Volumes/SanDisk/a/keep.mov", g)
        let q = build([k, extra("/Volumes/SanDisk/b/copy1.mov", g), extra("/Volumes/SanDisk/c/copy2.mov", g)])
        let set = try #require(q.cases.first { $0.kind == .reclaimGroup })
        let size = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        #expect(set.id == "dup:" + g.uuidString)
        #expect(set.title == "3 copies over 1 drive · \(size(3 * GB)) · keep the one on SanDisk · reclaim \(size(2 * GB))")
        #expect(set.payoffBytes == 2 * GB && set.actionableBytes == 2 * GB)
        #expect(set.facts == StewardFacts(bytes: 2 * GB, count: 3))
        #expect(set.keeperID == k.id)
        #expect(set.copies.first?.standing == .keeper, "the keeper is listed first")
        #expect(set.copies.dropFirst().allSatisfy { $0.standing == .wouldBeChecked })
        #expect(set.copies.map(\.folder).contains("b"), "each copy shows its folder under the drive")
        #expect(set.driveRoot == "/Volumes/SanDisk")
    }

    @Test func copiesOnAnotherDriveThanTheKeeperAreOfferedOnlyWithWorkingCopyCleanup() throws {
        let g = UUID()
        let inputs = [keeper("/Volumes/LaCie/master.mov", g), extra("/Volumes/SanDisk/working.mov", g),
                      extra("/Volumes/X9/working.mov", g, bytes: 2 * GB)]
        let off = build(inputs)
        #expect(off.cases.contains { $0.kind == .reclaimDrive } == false, "the flow would check nothing on any drive")
        let set = try #require(off.cases.first { $0.kind == .reclaimGroup })
        #expect(set.title.hasPrefix("3 copies over 3 drives"))
        #expect(set.payoffBytes == 3 * GB, "what could come back is still shown")
        #expect(set.actionableBytes == 0 && set.copiesNeedingWorkingCopyMode == 2)
        #expect(set.copies.filter { $0.standing == .keeperOnAnotherDrive }.count == 2)
        #expect(set.driveRoot == "/Volumes/X9", "the action names the drive where most could come back")

        let on = build(inputs, crossMode: true)
        let onSet = try #require(on.cases.first { $0.kind == .reclaimGroup })
        #expect(onSet.actionableBytes == 3 * GB && onSet.copiesNeedingWorkingCopyMode == 0)
        #expect(on.cases.filter { $0.kind == .reclaimDrive }.map(\.driveLabel).sorted() == ["SanDisk", "X9"])
    }

    @Test func aSetWithNoKeeperOrOnlyReviewRowsProposesNothing() {
        let g = UUID(), h = UUID()
        let q = build([
            extra("/Volumes/SanDisk/a.mov", g), extra("/Volumes/SanDisk/b.mov", g),            // no keeper elected
            keeper("/Volumes/SanDisk/k.mov", h),
            StewardInput(fullPath: "/Volumes/SanDisk/review.mov", duplicateGroupID: h),        // a Review row
        ])
        #expect(q.cases.isEmpty)
    }

    @Test func aDriveThatIsNotConnectedStillGetsItsCardMarkedSo() throws {
        let g = UUID()
        let q = build([keeper("/Volumes/Gone/k.mov", g), extra("/Volumes/Gone/c.mov", g)])
        let drive = try #require(q.cases.first { $0.kind == .reclaimDrive })
        #expect(drive.driveConnected == false)
        #expect(q.cases.first { $0.kind == .reclaimGroup }?.copies.allSatisfy { !$0.isOnline } == true)
    }

    // Same footage

    @Test func aLikelyFootageGroupGetsACardWithItsMembersOriginalDatesAndReasons() throws {
        let g = UUID()
        let original = clip("/Volumes/LaCie/tapes/xmas.mov", footage: g, rank: 0, best: day(2006, 12, 20),
                            evidence: ["same name + length as xmas copy.mov"])
        let q = build([
            original,
            clip("/Volumes/SanDisk/xmas copy.mov", footage: g, rank: 1, original: original.id, best: day(2006, 12, 28),
                 evidence: ["same name + length as xmas copy.mov", "re-encode of xmas.mov"]),
            clip("/Volumes/SanDisk/xmas small.mov", footage: g, rank: 2, original: original.id, best: day(2006, 12, 22)),
        ].map { var r = $0; r.footageLikelyOriginalID = original.id; return r })
        let c = try #require(q.cases.first { $0.kind == .sameFootage })
        #expect(c.id == "footage:" + g.uuidString)
        #expect(c.title == "3 clips on 2 drives — likely the same footage · Dec 2006")
        #expect(c.plainDescription == c.title && c.eventGuess == nil && c.detail.isEmpty)
        #expect(c.memberCount == 3 && c.facts == StewardFacts(bytes: 3 * GB, count: 3))
        #expect(c.likelyOriginalID == original.id && c.likelyOriginalName == "xmas.mov")
        #expect(c.copies.map(\.filename) == ["xmas.mov", "xmas copy.mov", "xmas small.mov"], "likely original first")
        #expect(c.copies.first?.roleLabel == "likely original")
        #expect(c.evidenceLines == ["same name + length as xmas copy.mov", "re-encode of xmas.mov"], "the group's reasons, once each")
        #expect(c.driveRoot == nil, "a Same-footage card has no drive to clean")
    }

    @Test func possibleGroupsAndSingleMembersGetNoCardAndStrongerGroupsSayHowSure() {
        let weak = UUID(), lone = UUID(), identical = UUID(), confirmed = UUID()
        let q = build([
            clip("/Volumes/LaCie/a.mov", footage: weak, strength: 0), clip("/Volumes/LaCie/b.mov", footage: weak, strength: 0),
            clip("/Volumes/LaCie/c.mov", footage: lone),
            clip("/Volumes/LaCie/d.mov", footage: identical, strength: 3), clip("/Volumes/LaCie/e.mov", footage: identical, strength: 3),
            clip("/Volumes/LaCie/f.mov", footage: confirmed, strength: 2), clip("/Volumes/LaCie/g.mov", footage: confirmed, strength: 2),
        ])
        let titles = q.cases.filter { $0.kind == .sameFootage }.map(\.title)
        #expect(titles.count == 2)
        #expect(titles.contains("2 clips on 1 drive — the same footage, byte for byte"))
        #expect(titles.contains("2 clips on 1 drive — the same footage (you confirmed)"))
    }

    @Test func footageGroupsAreOrderedByMemberCountThenBytes() {
        let big = UUID(), small = UUID(), heavy = UUID()
        var inputs: [StewardInput] = (0..<5).map { clip("/Volumes/LaCie/big\($0).mov", footage: big) }
        inputs += (0..<2).map { clip("/Volumes/LaCie/small\($0).mov", footage: small) }
        inputs += (0..<2).map { i in var r = clip("/Volumes/LaCie/heavy\(i).mov", footage: heavy); r.sizeBytes = 9 * GB; return r }
        let order = build(inputs).cases.filter { $0.kind == .sameFootage }.map(\.footageGroupID)
        #expect(order == [big, heavy, small])
    }

    @Test func dateSpansReadAsMonthsOrYears() {
        #expect(StewardCaseBuilder.dateSpanText(earliest: day(2006, 12, 2), latest: day(2006, 12, 30), calendar: utc) == "Dec 2006")
        #expect(StewardCaseBuilder.dateSpanText(earliest: day(2006, 12, 30), latest: day(2007, 1, 2), calendar: utc) == "Dec 2006 – Jan 2007")
        #expect(StewardCaseBuilder.dateSpanText(earliest: day(2004, 3, 1), latest: day(2006, 8, 1), calendar: utc) == "2004 – 2006")
        #expect(StewardCaseBuilder.dateSpanText(earliest: nil, latest: nil, calendar: utc).isEmpty)
    }

    @Test func aRecordsDatesAreDayPreciseOnlyWhenTheyAreKnownToTheDay() {
        let d = StewardCaseBuilder.dates
        #expect(d("1994-12-25", nil, false, nil, nil, utc).dayPrecise == day(1994, 12, 25), "a full date the person typed")
        #expect(d("1994-12", nil, false, nil, nil, utc).dayPrecise == nil)
        #expect(d("1994", nil, false, day(1994, 6, 1), nil, utc).dayPrecise == nil, "the person's year wins over the file's own date")
        #expect(d("1994", nil, false, nil, nil, utc).best == day(1994, 1, 1))
        #expect(d(nil, day(2001, 5, 6), false, nil, nil, utc).dayPrecise == day(2001, 5, 6))
        #expect(d(nil, day(2001, 5, 6), true, nil, nil, utc).dayPrecise == nil, "an inferred year RANGE is not a day")
        #expect(d(nil, day(2001, 1, 1), false, nil, nil, utc).dayPrecise == nil, "1 January is a year placeholder")
        #expect(d(nil, nil, false, day(2010, 7, 4), nil, utc).dayPrecise == day(2010, 7, 4), "the date written in the file")
        let copied = d(nil, nil, false, nil, day(2020, 3, 3), utc)
        #expect(copied.best == day(2020, 3, 3) && copied.dayPrecise == nil, "a file-system date is never day-precise")
    }

    // Probably not worth keeping

    @Test func junkRowsClusterByReasonAndDrive() throws {
        let q = build([
            junk("/Volumes/SanDisk/a.mov"), junk("/Volumes/SanDisk/b.mov", reasons: ["Very short (0.4s)"]),
            junk("/Volumes/SanDisk/c.mov", reasons: ["Duplicate extra copy (original exists)", "Very short (1.0s)"]),
            junk("/Volumes/LaCie/d.mov"), junk("/Volumes/LaCie/e.mov"),
            junk("/Volumes/SanDisk/z.mov", reasons: ["Zero-byte file"]),                     // a cluster of one: no card
        ])
        let cards = q.cases.filter { $0.kind == .junk }
        #expect(cards.map(\.title) == ["3 very short clips on SanDisk", "2 very short clips on LaCie"])
        let first = try #require(cards.first)
        #expect(first.id == "junk:Very short|/Volumes/SanDisk")
        #expect(first.recordIDs.count == 3 && first.facts.count == 3)
        #expect(first.junkReason == "Very short")
    }

    @Test func onlyUndecidedRowsAtOrAboveTriagesThresholdInTriagesTableCount() {
        #expect(StewardCaseBuilder.junkThreshold == 5)
        let q = build([
            junk("/Volumes/SanDisk/low1.mov", score: 4), junk("/Volumes/SanDisk/low2.mov", score: 4),
            junk("/Volumes/SanDisk/kept1.mov", undecided: false), junk("/Volumes/SanDisk/kept2.mov", undecided: false),
            junk("/Volumes/SanDisk/filed1.mov", inTriage: false), junk("/Volumes/SanDisk/filed2.mov", inTriage: false),
            junk("/Volumes/SanDisk/none1.mov", reasons: []), junk("/Volumes/SanDisk/none2.mov", reasons: []),
            junk("/Volumes/SanDisk/dup1.mov", reasons: ["Duplicate extra copy (original exists)"]),
            junk("/Volumes/SanDisk/dup2.mov", reasons: ["Duplicate extra copy (original exists)"]),
        ])
        #expect(q.cases.isEmpty, "below the line, already decided, filed as Archived, no reason, or Reclaim's business")
    }

    @Test func reasonsLoseTheirBracketedNumbersAndGetFamilyWords() {
        #expect(StewardCaseBuilder.junkReasonKey(["Very short (2.1s)"]) == "Very short")
        #expect(StewardCaseBuilder.junkReasonKey(["Short audio-only clip (<30s), no pair found"]) == "Short audio-only clip, no pair found")
        #expect(StewardCaseBuilder.junkReasonKey(["Screencast resolution (1920x1200), no audio"]) == "Screencast resolution, no audio")
        #expect(StewardCaseBuilder.junkReasonKey(["Low audio sample rate (8000 Hz) — voicemail/VoIP"]) == "Low audio sample rate — voicemail/VoIP")
        #expect(StewardCaseBuilder.junkReasonKey(["File appears truncated (size << expected)"]) == "File appears truncated")
        #expect(StewardCaseBuilder.junkReasonKey([]) == nil)
        #expect(StewardCaseBuilder.junkNoun("Very short") == "very short clips")
        #expect(StewardCaseBuilder.junkNoun("Short audio-only clip, no pair found") == "short sound-only clips")
        #expect(StewardCaseBuilder.junkNoun("Something new") == "files marked “Something new”")
    }

    // Queue

    @Test func theThreeKindsTakeTurnsEachInItsOwnOrder() {
        let g = UUID(), h = UUID(), f = UUID()
        var inputs = [keeper("/Volumes/SanDisk/k1.mov", g), extra("/Volumes/SanDisk/c1.mov", g, bytes: 5 * GB),
                      keeper("/Volumes/LaCie/k2.mov", h), extra("/Volumes/LaCie/c2.mov", h, bytes: 2 * GB)]
        inputs += (0..<3).map { clip("/Volumes/X9/f\($0).mov", footage: f) }
        inputs += (0..<2).map { junk("/Volumes/X9/j\($0).mov") }
        let q = build(inputs)
        #expect(q.isBuilt)
        #expect(q.cases.map(\.kind.lane) == [0, 1, 2, 0, 0, 0], "Reclaim, Same footage, Not worth keeping, then the rest of Reclaim")
        let reclaim = q.cases.filter { $0.kind.lane == 0 }
        #expect(reclaim.map(\.payoffBytes) == [5 * GB, 5 * GB, 2 * GB, 2 * GB], "largest first; a drive and its one set tie")
        #expect(Set(q.cases.map(\.id)).count == q.cases.count, "case ids are unique")
    }

    @Test func theSameInputsBuildAnEqualQueue() {
        let g = UUID()
        let inputs = [keeper("/Volumes/SanDisk/k.mov", g), extra("/Volumes/SanDisk/c.mov", g)]
        #expect(build(inputs) == build(inputs), "nothing time-dependent is in the queue — the snapshot's gate holds")
    }

    @Test func theNewestDuplicateCheckIsCarried() {
        var a = StewardInput(fullPath: "/Volumes/SanDisk/a.mov"), b = StewardInput(fullPath: "/Volumes/SanDisk/b.mov")
        a.dupAnalyzedAt = Date(timeIntervalSince1970: 100)
        b.dupAnalyzedAt = Date(timeIntervalSince1970: 900)
        #expect(build([a, b]).duplicatesLastChecked == Date(timeIntervalSince1970: 900))
        #expect(build([]).duplicatesLastChecked == nil)
    }

    @Test func driveRootsMatchTheDeleteFlowsVolumeList() {
        #expect(StewardCaseBuilder.driveRoot(of: "/Volumes/X9/a/b.mov", scanRoots: []) == "/Volumes/X9")
        #expect(StewardCaseBuilder.driveRoot(of: "/Volumes/X9-Old/a.mov", scanRoots: ["/Volumes/X9"]) == "/Volumes/X9-Old")
        #expect(StewardCaseBuilder.driveRoot(of: "/Users/me/Movies/a/b.mov", scanRoots: ["/Users/me/Movies"]) == "/Users/me/Movies")
        #expect(StewardCaseBuilder.driveRoot(of: "/Users/me/Other/b.mov", scanRoots: ["/Users/me/Movies"]) == "/Users/me/Other")
        #expect(StewardCaseBuilder.isConnected("/Volumes/Gone", mountedRoots: mounted) == false)
        #expect(StewardCaseBuilder.isConnected("/Users/me/Movies", mountedRoots: mounted))
    }
}

// MARK: - Words

@Suite("Steward — the words: freshness, button states, keeper reason, log line")
struct StewardWordsTests {

    @Test func freshnessSaysWhenAndHowManyAreLeft() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var counts = AnalyzeCoverageCounts()
        counts.eligible = 100
        counts.covered = 86
        let line = StewardFreshness.duplicates(lastChecked: now.addingTimeInterval(-7_200), counts: counts, now: now)
        #expect(line.hasPrefix("duplicates checked "))
        #expect(line.hasSuffix(" · 14 files not checked yet"))
        counts.covered = 100
        #expect(!StewardFreshness.duplicates(lastChecked: now, counts: counts, now: now).contains("not checked yet"))
        #expect(StewardFreshness.duplicates(lastChecked: nil, counts: AnalyzeCoverageCounts(), now: now) == "duplicates not checked yet")

        var footage = AnalyzeCoverageCounts()
        #expect(StewardFreshness.footage(counts: footage, now: now) == "same footage not looked for yet")
        footage.newestStamp = now.addingTimeInterval(-3_600)
        footage.secondary = 2_410
        let footageLine = StewardFreshness.footage(counts: footage, now: now)
        #expect(footageLine.hasPrefix("same footage looked for ") && footageLine.hasSuffix(" · 2,410 files grouped"))
    }

    /// Rule 2's last clause: a read-only viewer is offered nothing that
    /// changes anything, and every "off" says why.
    @Test func deleteIsOffWithAReasonWhenReadOnlyOrTheDriveIsAway() {
        func gate(readOnly: Bool = false, running: Bool = false, label: String = "SanDisk", connected: Bool = true,
                  offered: Bool = true, needsMode: Bool = false) -> StewardActionGate {
            StewardActionGate.deleteDuplicates(isReadOnly: readOnly, isDeleteRunning: running, driveLabel: label,
                                               driveConnected: connected, offeredByDeleteFlow: offered,
                                               needsWorkingCopyMode: needsMode)
        }
        #expect(gate().isEnabled)
        #expect(gate(readOnly: true) == StewardActionGate(isEnabled: false, reason: "This Mac is a read-only viewer of the catalog."))
        #expect(gate(connected: false) == StewardActionGate(isEnabled: false, reason: "SanDisk is not connected — connect it first."))
        #expect(gate(running: true).isEnabled == false)
        #expect(gate(offered: false).reason == "No duplicate copies on SanDisk can be deleted right now.")
        #expect(gate(offered: false, needsMode: true).reason.contains(WorkingCopyCleanupText.toggleLabel))
        #expect(gate(label: "").isEnabled == false)
        // Read-only outranks everything else.
        #expect(gate(readOnly: true, connected: false, offered: false).reason == "This Mac is a read-only viewer of the catalog.")
        #expect(StewardActionGate.catalogAction(isReadOnly: true, help: "x").isEnabled == false)
        #expect(StewardActionGate.catalogAction(isReadOnly: false, help: "x") == StewardActionGate(isEnabled: true, reason: "x"))
    }

    @Test func theKeeperReasonIsTheFirstThingItWonOn() {
        typealias Key = DuplicateKeeperPolicy.ElectionKey
        func key(_ a: Int = 2, _ p: Int = 30, _ h: Int = 0, _ t: Int = 10, _ path: String = "/b") -> Key {
            Key(availability: a, precedence: p, humanMetadata: h, technical: t, path: path)
        }
        func words(_ k: Key, _ others: [Key], archive: Bool = false) -> String {
            StewardKeeperReason.words(keeper: k, others: others, keeperDrive: "LaCie", keeperIsInArchive: archive)
        }
        #expect(words(key(), []) == "It is the only copy in the set.")
        #expect(words(key(2), [key(1)]).contains("connected and in use"))
        #expect(words(key(2, 99_999), [key(2, 30)]) == "Its drive, LaCie, comes first in your drive order.")
        #expect(words(key(2, 1_000_000), [key(2, 30)], archive: true) == "It is the copy in the Master Archive.")
        #expect(words(key(2, 30, 100), [key(2, 30, 0)]).contains("your own marks"))
        #expect(words(key(2, 30, 0, 20), [key(2, 30, 0, 10)]) == "It is the best-quality copy.")
        #expect(words(key(2, 30, 0, 10, "/a"), [key(2, 30, 0, 10, "/b")]) == "The copies are equal, so the first by name was chosen.")
        #expect(words(key(2, 30), [key(2, 99_999)]).contains("next duplicate check will choose again"),
                "a keeper the current drive order would not choose is said to be stale, not defended")
    }

    /// No person's name, no title, no filename, no folder in a log line.
    @Test func logLinesCarryTheKindAndNumbersButNeverATitleOrAName() {
        let g = UUID()
        var c = StewardCase(id: "footage:" + g.uuidString, kind: .sameFootage, title: "Around Alex's 1st birthday?",
                            facts: StewardFacts(bytes: 3 * GB, count: 12))
        c.footageGroupID = g
        c.copies = [StewardCopy(id: UUID(), filename: "alex party.mov", drive: "SanDisk", folder: "Tapes/Alex",
                                sizeBytes: GB, durationSeconds: 60, isOnline: true, standing: .member)]
        let line = StewardLog.line(.shown, c)
        #expect(line.hasPrefix("Steward: shown — Same footage [footage \(g.uuidString.prefix(8))] · 12 files · "))
        #expect(!line.contains("Alex") && !line.contains("alex") && !line.contains("Tapes"))

        var d = StewardCase(id: "drive:/Volumes/SanDisk", kind: .reclaimDrive, title: "t", facts: StewardFacts(bytes: GB, count: 1))
        d.driveLabel = "SanDisk"
        #expect(StewardLog.line(.acted, d, action: "Show these in the Catalog")
                == "Steward: acted — Reclaim space [drive SanDisk] · 1 file · \(ByteCountFormatter.string(fromByteCount: GB, countStyle: .file)) · Show these in the Catalog")
        #expect(StewardLog.line(.skipped, d).hasPrefix("Steward: skipped — "))
        #expect(StewardLog.line(.broughtBack, d).hasPrefix("Steward: brought back — "))
    }

    @Test func aProofReadsAsWhoRemainsAndWhatWouldHappen() {
        let id = UUID()
        let three = StewardCopyProof(copyID: id, remaining: 3, counted: ["keeper on LaCie", "archive copy on FamilyArchive", "sibling b.mov on X9"],
                                     notCounted: 0, tier: .permanent, hadStoredDigest: true)
        #expect(three.remainLine == "3 verified copies would remain: keeper on LaCie, archive copy on FamilyArchive, sibling b.mov on X9")
        #expect(three.outcomeLine == "It would be deleted outright." && three.caveatLine == nil)
        let two = StewardCopyProof(copyID: id, remaining: 2, counted: ["keeper on LaCie", "sibling"], notCounted: 1, tier: .trash, hadStoredDigest: true)
        #expect(two.outcomeLine == "It would go to the Trash, not be deleted.")
        #expect(two.caveatLine == "1 other copy could not be counted yet — the run reads them if it needs to.")
        let one = StewardCopyProof(copyID: id, remaining: 1, counted: ["keeper on LaCie"], notCounted: 0, tier: nil, hadStoredDigest: false)
        #expect(one.remainLine == "1 verified copy would remain: keeper on LaCie" && one.outcomeLine == "It would be left alone.")
        #expect(one.caveatLine?.contains("has not been read yet") == true)
    }
}

// MARK: - Skip memory (isolated defaults)

@Suite("Steward — Skip is remembered until the facts move", .serialized)
struct StewardSkipStoreTests {

    /// A UserDefaults suite of its own, removed afterwards — never Rick's.
    private func withStore(_ body: (StewardSkipStore, UserDefaults) -> Void) {
        let name = "steward-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("could not make an isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: name) }
        body(StewardSkipStore(defaults: defaults), defaults)
    }

    private func item(_ id: String = "dup:A", bytes: Int64 = 10 * GB, count: Int = 4) -> StewardCase {
        StewardCase(id: id, kind: .reclaimGroup, title: "t", facts: StewardFacts(bytes: bytes, count: count))
    }

    @Test func aSkippedCaseLeavesTheQueueAndBringBackReturnsIt() {
        withStore { store, defaults in
            let a = item("dup:A"), b = item("footage:B")
            #expect(store.partition([a, b]).active.map(\.id) == ["dup:A", "footage:B"])
            store.skip(a)
            #expect(defaults.string(forKey: "steward.skipped.dup:A") == "v1|\(10 * GB)|4", "key = steward.skipped.<caseID>")
            let parts = store.partition([a, b])
            #expect(parts.active.map(\.id) == ["footage:B"] && parts.skipped.map(\.id) == ["dup:A"])
            // …and it is still skipped for a NEW store over the same defaults (the next launch).
            #expect(StewardSkipStore(defaults: defaults).isSkipped(a))
            store.bringBack(caseID: "dup:A")
            #expect(store.partition([a, b]).skipped.isEmpty)
            #expect(defaults.object(forKey: "steward.skipped.dup:A") == nil)
        }
    }

    @Test func itComesBackWhenTheCountOrTheSizeMovesByATenth() {
        withStore { store, _ in
            store.skip(item(bytes: 10 * GB, count: 4))
            #expect(store.isSkipped(item(bytes: 10 * GB, count: 4)))
            #expect(store.isSkipped(item(bytes: 10 * GB + GB / 2, count: 4)), "5% more bytes is not material")
            #expect(!store.isSkipped(item(bytes: 11 * GB, count: 4)), "10% more bytes is")
            #expect(!store.isSkipped(item(bytes: 9 * GB, count: 4)), "…and 10% fewer")
            #expect(!store.isSkipped(item(bytes: 10 * GB, count: 5)), "one more copy in a set of four is material")
            #expect(!store.isSkipped(item(bytes: 10 * GB, count: 3)))

            let drive = StewardCase(id: "drive:/Volumes/SanDisk", kind: .reclaimDrive, title: "t",
                                    facts: StewardFacts(bytes: 400 * GB, count: 1_208))
            store.skip(drive)
            var moved = drive
            moved.facts = StewardFacts(bytes: 401 * GB, count: 1_210)
            #expect(store.isSkipped(moved), "two more copies on a drive of 1,208 is not material")
            moved.facts = StewardFacts(bytes: 401 * GB, count: 1_329)
            #expect(!store.isSkipped(moved), "a tenth more is")
        }
    }

    @Test func theRuleIsATenthAndAtLeastOneFile() {
        let rule = StewardSkipStore.isMaterialChange
        #expect(!rule(StewardFacts(bytes: 0, count: 0), StewardFacts(bytes: 0, count: 0)))
        #expect(rule(StewardFacts(bytes: 0, count: 0), StewardFacts(bytes: 1, count: 0)), "anything from nothing is material")
        #expect(rule(StewardFacts(bytes: 100, count: 2), StewardFacts(bytes: 100, count: 3)))
        #expect(!rule(StewardFacts(bytes: 100, count: 100), StewardFacts(bytes: 100, count: 109)))
        #expect(rule(StewardFacts(bytes: 100, count: 100), StewardFacts(bytes: 100, count: 110)))
    }

    /// Poisoned state: whatever is under the key, the case is shown rather
    /// than hidden, and nothing crashes.
    @Test func aValueThatCannotBeReadNeverHidesACase() {
        withStore { store, defaults in
            let a = item("dup:A")
            let key = StewardSkipStore.key(for: "dup:A")
            let poison: [Any] = [42, true, Date(), ["v1|1|1"], Data([0xFF, 0x00]), "", "garbage", "v0|1|1", "v1|x|4",
                                 "v1|10|", "v1|-5|4", "v1|10|-1", "v1|10|4|extra", "v1||", "9999999999999999999999|1|1"]
            for value in poison {
                defaults.set(value, forKey: key)
                #expect(!store.isSkipped(a), "poisoned value \(value) hid the case")
                #expect(store.rememberedFacts(caseID: "dup:A") == nil)
                #expect(store.partition([a]).active.count == 1)
            }
            // A skip after the poison writes a good value over it.
            store.skip(a)
            #expect(store.isSkipped(a))
        }
    }

    @Test func factsRoundTripThroughTheStoredValue() {
        let facts = StewardFacts(bytes: 412_000_000_000, count: 1_208)
        #expect(StewardSkipStore.decode(StewardSkipStore.encode(facts)) == facts)
    }

    /// Isolation: the Catalog door adds ONE filter to whatever is stored,
    /// through the Catalog's own encoder, in the defaults it is handed.
    @Test func theCatalogDoorAddsOnePerFootageAndKeepsTheOtherFilters() {
        withStore { _, defaults in
            defaults.set(CatalogShowingSummary.encode([.notYetArchived, .ratedOnly]), forKey: StewardCatalogDoor.viewFiltersKey)
            StewardCatalogDoor.turnOnOnePerFootage(in: defaults)
            let after = CatalogShowingSummary.decode(defaults.string(forKey: StewardCatalogDoor.viewFiltersKey) ?? "")
            #expect(after == [.notYetArchived, .ratedOnly, .onePerFootage])
            StewardCatalogDoor.turnOnOnePerFootage(in: defaults)
            #expect(CatalogShowingSummary.decode(defaults.string(forKey: StewardCatalogDoor.viewFiltersKey) ?? "") == after, "idempotent")
            // Poisoned: a non-string under the key is treated as "no filters".
            defaults.set(7, forKey: StewardCatalogDoor.viewFiltersKey)
            StewardCatalogDoor.turnOnOnePerFootage(in: defaults)
            #expect(CatalogShowingSummary.decode(defaults.string(forKey: StewardCatalogDoor.viewFiltersKey) ?? "") == [.onePerFootage])
        }
    }
}

// MARK: - Scale

@Suite("Steward — scale")
struct StewardScaleTests {

    /// 100k records over five drives: 2,000 duplicate sets of 4, 3,000
    /// footage groups of 5 (each with a day-precise date; the 25 that make
    /// the cut are guessed against 40 people), 20,000 junk rows in 40
    /// clusters. One build under 3 s in
    /// Debug — it runs off the main actor, once per debounced catalog change.
    @Test func hundredThousandRecordsBuildUnderBudget() {
        let drives = ["/Volumes/SanDisk", "/Volumes/LaCie", "/Volumes/X9", "/Volumes/Gone", "/Volumes/Extra"]
        let scaleVolumes = drives.map { AnalyzeVolumeFact(root: $0, isReachable: $0 != "/Volumes/Gone", isRetired: false) }
        let dupGroups = (0..<2_000).map { _ in UUID() }
        let footageGroups = (0..<3_000).map { _ in UUID() }
        let reasons = ["Very short (1.2s)", "Zero-byte file", "Avid render/precompute file", "System/hidden directory artifact",
                       "Filename suggests test/temp/sample content", "Zero duration", "File appears truncated (size << expected)",
                       "Screencast resolution (1920x1200), no audio"]
        var inputs: [StewardInput] = []
        inputs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            var r = StewardInput(fullPath: "\(drives[i % 5])/folder\(i % 400)/clip\(i).mov", sizeBytes: Int64(1 + i % 9) * 100_000_000)
            if i < 8_000 {
                r.duplicateGroupID = dupGroups[i % 2_000]
                r.isKeeper = i < 2_000
                r.isExtraCopy = i >= 2_000
                r.hasUsableDigest = i % 3 == 0
                r.protection = i % 97 == 0 ? .archiveDrive : .none
            } else if i < 23_000 {
                let g = (i - 8_000) % 3_000
                r.footageGroupID = footageGroups[g]
                r.footageStrength = 1 + g % 3
                r.footageRank = (i - 8_000) / 3_000
                r.footageEvidence = ["same name + length as clip\(g).mov"]
                r.dayPreciseDate = day(1990 + g % 30, 1 + g % 12, 1 + g % 28)
                r.bestDate = r.dayPreciseDate
            } else if i < 43_000 {
                r.junkScore = 5 + i % 4
                r.junkReasonKey = StewardCaseBuilder.junkReasonKey([reasons[i % reasons.count]])
            }
            r.dupAnalyzedAt = i % 4 == 0 ? nil : Date(timeIntervalSince1970: Double(i))
            inputs.append(r)
        }
        let people = (0..<40).map {
            StewardEventGuess.Person(displayName: "Person \($0)", birthYear: 1950 + $0, birthMonth: 1 + $0 % 12, birthDay: 1 + $0 % 28)
        }
        let start = ContinuousClock.now
        let q = StewardCaseBuilder.build(inputs: inputs, volumes: scaleVolumes,
                                         mountedRoots: ["/", "/Volumes/SanDisk", "/Volumes/LaCie", "/Volumes/X9", "/Volumes/Extra"],
                                         alsoCleanUpWorkingCopies: true, people: people, calendar: utc)
        let elapsed = ContinuousClock.now - start
        #expect(q.isBuilt)
        #expect(q.count(of: .reclaimGroup) == StewardCaseBuilder.maxCasesPerKind)
        #expect(q.count(of: .reclaimDrive) == 5)
        #expect(q.count(of: .sameFootage) == StewardCaseBuilder.maxCasesPerKind)
        #expect(q.count(of: .junk) == StewardCaseBuilder.maxCasesPerKind)
        #expect(q.cases.count <= 4 * StewardCaseBuilder.maxCasesPerKind, "the queue is bounded whatever the catalog's size")
        #expect(q.cases.allSatisfy { $0.copies.count <= StewardCaseBuilder.maxCopiesPerCase && $0.recordIDs.count <= StewardCaseBuilder.maxIDsPerCase })
        #expect(elapsed < PerformanceLane.debugCeiling(.milliseconds(3_000)),
                "steward build took \(elapsed) for 100k records — over the 3 s budget")
    }

    /// The guess is per GROUP, not per record: 3,000 groups × 40 people.
    @Test func guessingForThreeThousandGroupsIsQuick() {
        let people = (0..<40).map {
            StewardEventGuess.Person(displayName: "Person \($0)", birthYear: 1950 + $0, birthMonth: 1 + $0 % 12, birthDay: 1 + $0 % 28)
        }
        let start = ContinuousClock.now
        var guessed = 0
        for g in 0..<3_000 {
            let d = day(1990 + g % 30, 1 + g % 12, 1 + g % 28)
            if StewardEventGuess.guess(groupDateSpan: .init(earliest: d, latest: d), people: people, calendar: utc) != nil { guessed += 1 }
        }
        let elapsed = ContinuousClock.now - start
        #expect(guessed > 0)
        #expect(elapsed < PerformanceLane.debugCeiling(.milliseconds(1_500)), "3,000 guesses took \(elapsed)")
    }
}
