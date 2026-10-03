// StewardCaseBuilderTests.swift
// The content steward's case builder and skip memory (trial UI, 2026-10-03;
// design §5.6 of docs/design/analyze_knowledge_and_storage_actions_2026-10-02.md).
//
// Five-dimension coverage (CLAUDE.md checklist):
//   Logic     — each housekeeping card type (Reclaim per drive, Reclaim per
//               set, Same footage, Probably not worth keeping), the lane
//               order, the words (freshness, button states, keeper reason,
//               log line), skip → stays away → comes back on a material
//               change → Bring back. The Events lane is in
//               StewardEventsTests.swift.
//   Scale     — 100k records, 2k duplicate sets, 3k footage groups, 20k
//               junk rows, 57k dated clips labelled against 40 birthdays:
//               explicit budget.
//   Isolation — the skip memory and the Catalog door run against their own
//               UserDefaults suite; a poisoned value never hides a case and
//               never crashes.
//   Sensor    — StewardSensorTests.swift (source-level).
// Media matrix: N/A — catalog metadata only, no media is opened.
//
// The two §5.6 rules (proof = the Delete planner's; exclusions) are in
// StewardRulesTests.swift. Events, days to name and the Same-footage title
// guess are in StewardEventsTests.swift.
//
// Suites: StewardCaseBuilderLogicTests · StewardWordsTests ·
//         StewardSkipStoreTests · StewardScaleTests

import Foundation
import Testing
import VideoScanCore
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

/// A fixed "now" (2026): it only bounds the resolver's search for a year in a name.
private let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

private func build(_ inputs: [StewardInput], crossMode: Bool = false, skipped: [String: StewardFacts] = [:]) -> StewardQueue {
    StewardCaseBuilder.build(inputs: inputs, volumes: volumes, mountedRoots: mounted,
                             alsoCleanUpWorkingCopies: crossMode, skipped: skipped, calendar: utc, now: fixedNow)
}

private func keeper(_ path: String, _ g: UUID, bytes: Int64 = GB) -> StewardInput {
    StewardInput(fullPath: path, sizeBytes: bytes, isKeeper: true, duplicateGroupID: g, hasUsableDigest: true)
}

private func extra(_ path: String, _ g: UUID, bytes: Int64 = GB,
                   protection: StewardProtection = .none) -> StewardInput {
    StewardInput(fullPath: path, sizeBytes: bytes, isExtraCopy: true, duplicateGroupID: g, protection: protection)
}

private func clip(_ path: String, footage g: UUID, strength: Int = 1, rank: Int = 0, original: UUID? = nil,
                  best: Date? = nil, evidence: [String] = []) -> StewardInput {
    StewardInput(fullPath: path, sizeBytes: GB, footageGroupID: g, footageStrength: strength, footageRank: rank,
                 footageRoleLabel: rank == 0 ? "likely original" : "copy", footageLikelyOriginalID: original,
                 footageEvidence: evidence, bestDate: best)
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
        #expect(set.id == "dup:" + k.id.uuidString, "keyed by the keeper's record id (QA F5)")
        #expect(set.duplicateGroupID == g)
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
        // `bestDate` alone (a file-system date, say) gives the card its
        // month span and places nothing: no trusted day, no title guess.
        let original = clip("/Volumes/LaCie/tapes/reel.mov", footage: g, rank: 0, best: day(2006, 12, 20),
                            evidence: ["same name + length as reel copy.mov"])
        let q = build([
            original,
            clip("/Volumes/SanDisk/reel copy.mov", footage: g, rank: 1, original: original.id, best: day(2006, 12, 28),
                 evidence: ["same name + length as reel copy.mov", "re-encode of reel.mov"]),
            clip("/Volumes/SanDisk/reel small.mov", footage: g, rank: 2, original: original.id, best: day(2006, 12, 22)),
        ].map { var r = $0; r.footageLikelyOriginalID = original.id; return r })
        let c = try #require(q.cases.first { $0.kind == .sameFootage })
        #expect(c.id == "footage:" + g.uuidString)
        #expect(c.title == "3 clips on 2 drives — likely the same footage · Dec 2006")
        #expect(c.plainDescription == c.title && c.occasionGuess == nil && c.detail.isEmpty)
        #expect(c.memberCount == 3 && c.facts == StewardFacts(bytes: 3 * GB, count: 3))
        #expect(c.likelyOriginalID == original.id && c.likelyOriginalName == "reel.mov")
        #expect(c.copies.map(\.filename) == ["reel.mov", "reel copy.mov", "reel small.mov"], "likely original first")
        #expect(c.copies.first?.roleLabel == "likely original")
        #expect(c.evidenceLines == ["same name + length as reel copy.mov", "re-encode of reel.mov"], "the group's reasons, once each")
        #expect(q.cases.allSatisfy { $0.kind != .event && $0.kind != .unlabelledDay }, "undated clips with plain names are in no event")
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

    /// The Same-footage card's month span reads the best date at ANY
    /// precision. What day a clip records is the Angel's rule, tested in
    /// StewardEventsTests.
    @Test func theBestDateIsThePersonsThenTheInferredThenTheFilesThenTheFileSystems() {
        let d = StewardCaseBuilder.bestDate
        #expect(d("1994-12-25", day(2001, 5, 6), day(2010, 7, 4), nil, utc) == day(1994, 12, 25), "the person's date wins")
        #expect(d("1994", nil, day(1994, 6, 1), nil, utc) == day(1994, 1, 1), "a year reads as 1 January of it")
        #expect(d(nil, day(2001, 5, 6), day(2010, 7, 4), nil, utc) == day(2001, 5, 6))
        #expect(d(nil, nil, day(2010, 7, 4), day(2020, 3, 3), utc) == day(2010, 7, 4))
        #expect(d(nil, nil, nil, day(2020, 3, 3), utc) == day(2020, 3, 3))
        #expect(d("not a date", nil, nil, nil, utc) == nil)
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

    @Test func theHousekeepingLanesFollowInOrderEachInItsOwn() {
        let g = UUID(), h = UUID(), f = UUID()
        var inputs = [keeper("/Volumes/SanDisk/k1.mov", g), extra("/Volumes/SanDisk/c1.mov", g, bytes: 5 * GB),
                      keeper("/Volumes/LaCie/k2.mov", h), extra("/Volumes/LaCie/c2.mov", h, bytes: 2 * GB)]
        inputs += (0..<3).map { clip("/Volumes/X9/f\($0).mov", footage: f) }
        inputs += (0..<2).map { junk("/Volumes/X9/j\($0).mov") }
        let q = build(inputs)
        #expect(q.isBuilt)
        #expect(q.cases.map(\.kind.lane) == [2, 3, 3, 3, 3, 4], "Same footage, then Reclaim space, then Not worth keeping")
        let reclaim = q.cases.filter { $0.kind.lane == 3 }
        #expect(reclaim.map(\.payoffBytes) == [5 * GB, 5 * GB, 2 * GB, 2 * GB], "largest first; a drive and its one set tie")
        #expect(Set(q.cases.map(\.id)).count == q.cases.count, "ids are unique")
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

    @Test func theEventsCoverageLineSaysHowManyClipsCanBePlaced() {
        #expect(StewardFreshness.events(placed: 1_204, of: 9_310) == "1,204 of 9,310 clips have a date good enough to place")
        #expect(StewardFreshness.events(placed: 1, of: 1) == "1 of 1 clip has a date good enough to place")
        #expect(StewardFreshness.events(placed: 0, of: 0) == "no clips to place yet")
        let line = StewardFreshness.line(for: .event, duplicatesLastChecked: nil, report: AnalyzeCoverageReport(),
                                         now: Date(timeIntervalSince1970: 0), placedClips: 3, placeableClips: 7)
        #expect(line == "3 of 7 clips have a date good enough to place")
        #expect(StewardFreshness.line(for: .unlabelledDay, duplicatesLastChecked: nil, report: AnalyzeCoverageReport(),
                                      now: Date(timeIntervalSince1970: 0), placedClips: 3, placeableClips: 7) == line)
    }

    @Test func thePanesCountLineLeadsWithTheEvents() {
        #expect(StewardPaneWords.countLine(events: 42, days: 6, tidy: 31) == "42 events · 6 days to name · 31 tidy suggestions")
        #expect(StewardPaneWords.countLine(events: 1, days: 1, tidy: 1) == "1 event · 1 day to name · 1 tidy suggestion")
        #expect(StewardPaneWords.countLine(events: 0, days: 0, tidy: 2) == "2 tidy suggestions")
        #expect(StewardPaneWords.countLine(events: 0, days: 0, tidy: 0) == "nothing to show right now")
        #expect(StewardPaneWords.emptyLine(showSkipped: false, filter: .events, anythingAtAll: true)
                == "Nothing of this kind right now — choose All to see the rest.")
        #expect(StewardPaneWords.emptyLine(showSkipped: true, filter: .all, anythingAtAll: true) == "Nothing is skipped.")
        #expect(StewardPaneWords.emptyLine(showSkipped: false, filter: .all, anythingAtAll: false)
                == "No events found yet, and nothing to tidy right now.")
    }

    /// An event's log line: its KIND and its counts. Never its title (it
    /// can carry a person's name), never its year, never a filename.
    @Test func anEventsLogLineCarriesItsKindAndCountsOnly() {
        var c = StewardCase(id: "event:birthday:alex:1994", kind: .event, title: "Alex's 12th birthday",
                            facts: StewardFacts(bytes: 3 * GB, count: 14))
        c.eventKind = "birthday"
        c.eventYear = 1994
        c.detail = "14 clips · 3 drives · 2 h 10 m · Jun 10–12, 1994"
        c.copies = [StewardCopy(id: UUID(), filename: "alex party.mov", drive: "SanDisk", folder: "Tapes/Alex",
                                sizeBytes: GB, durationSeconds: 60, isOnline: true, standing: .member,
                                reason: "2 days after Alex's 12th birthday")]
        for verb in [StewardLog.Verb.shown, .skipped, .broughtBack, .acted] {
            let line = StewardLog.line(verb, c, action: verb == .acted ? "Show these in the Catalog" : nil)
            #expect(line.contains("— Event [occasion birthday] · 14 files · "))
            #expect(!line.contains("Alex") && !line.contains("alex") && !line.contains("12th") && !line.contains("1994")
                    && !line.contains("Tapes") && !line.contains(".mov"), "said: \(line)")
        }
        var d = StewardCase(id: "day:1996-07-14", kind: .unlabelledDay, title: "A day in July 1996",
                            facts: StewardFacts(bytes: GB, count: 9))
        d.eventYear = 1996
        let dayLine = StewardLog.line(.shown, d)
        #expect(dayLine.contains("— A day to name [a day with no name] · 9 files · ") && !dayLine.contains("1996"))
        #expect(StewardLog.viewLine(filter: .events, eventsByYear: true, listed: 42)
                == "Tidy suggestions: showing Events, events by year · 42 listed")
        #expect(StewardLog.viewLine(filter: .space, eventsByYear: false, listed: 3) == "Tidy suggestions: showing Space · 3 listed")
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
        #expect(line.hasPrefix("Tidy suggestions: shown — Same footage [footage \(g.uuidString.prefix(8))] · 12 files · "))
        #expect(!line.contains("Alex") && !line.contains("alex") && !line.contains("Tapes"))

        var d = StewardCase(id: "drive:/Volumes/SanDisk", kind: .reclaimDrive, title: "t", facts: StewardFacts(bytes: GB, count: 1))
        d.driveLabel = "SanDisk"
        #expect(StewardLog.line(.acted, d, action: "Show these in the Catalog")
                == "Tidy suggestions: acted — Reclaim space [drive SanDisk] · 1 file · \(ByteCountFormatter.string(fromByteCount: GB, countStyle: .file)) · Show these in the Catalog")
        #expect(StewardLog.line(.skipped, d).hasPrefix("Tidy suggestions: skipped — "))
        #expect(StewardLog.line(.broughtBack, d).hasPrefix("Tidy suggestions: brought back — "))
    }

    @Test func aProofReadsAsWhoRemainsAndWhatWouldHappen() {
        let id = UUID()
        let three = StewardCopyProof(copyID: id, remaining: 3, counted: ["keeper on LaCie", "archive copy on FamilyArchive", "sibling b.mov on X9"],
                                     notCounted: 0, tier: .permanent, hadStoredDigest: true, tierIfTheyMatch: .permanent)
        #expect(three.remainLine == "3 verified copies would remain: keeper on LaCie, archive copy on FamilyArchive, sibling b.mov on X9")
        #expect(three.outcomeLine == "It would be deleted outright." && three.caveatLine == nil)
        // QA F2: an outcome is flat ONLY when nothing was left uncounted.
        let two = StewardCopyProof(copyID: id, remaining: 2, counted: ["keeper on LaCie", "sibling"], notCounted: 1, tier: .trash,
                                   hadStoredDigest: true, tierIfTheyMatch: .trash)
        #expect(two.outcomeLine == "As things stand, it would go to the Trash, not be deleted.")
        #expect(two.caveatLine == "1 other copy was not counted — not connected, different, or part of the same cleanup.")
        let reads = StewardCopyProof(copyID: id, remaining: 2, counted: ["keeper on LaCie", "sibling"], notCounted: 1, tier: .trash,
                                     hadStoredDigest: true, readsFirst: 1, tierIfTheyMatch: .permanent)
        #expect(reads.outcomeLine == "The run reads 1 more copy first; if it matches, this copy would be deleted outright.")
        #expect(reads.caveatLine == nil)
        let twoReads = StewardCopyProof(copyID: id, remaining: 1, counted: ["keeper on LaCie"], notCounted: 2, tier: nil,
                                        hadStoredDigest: true, readsFirst: 2, tierIfTheyMatch: .permanent)
        #expect(twoReads.outcomeLine == "The run reads 2 more copies first; if they match, this copy would be deleted outright.")
        let unread = StewardCopyProof(copyID: id, remaining: 1, counted: ["keeper on LaCie"], notCounted: 1, tier: nil,
                                      hadStoredDigest: false, readsFirst: 1, tierIfTheyMatch: .trash)
        #expect(unread.remainLine == "1 verified copy would remain: keeper on LaCie")
        #expect(unread.outcomeLine == "The run reads this copy first; if the other copy matches, it would go to the Trash, not be deleted.")
        let alone = StewardCopyProof(copyID: id, remaining: 1, counted: ["keeper on LaCie"], notCounted: 0, tier: nil, hadStoredDigest: false)
        #expect(alone.outcomeLine == "The run reads this copy first; as things stand only the keeper would remain, so it would be left alone.")
        let flat = StewardCopyProof(copyID: id, remaining: 1, counted: ["keeper on LaCie"], notCounted: 0, tier: nil, hadStoredDigest: true)
        #expect(flat.outcomeLine == "It would be left alone.", "nothing uncounted, nothing to read: a flat outcome is honest")
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

    private func withStoreThrowing(_ body: (StewardSkipStore, UserDefaults) throws -> Void) throws {
        let name = "steward-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(StewardSkipStore(defaults: defaults), defaults)
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

    /// QA F4: the per-kind limit must not be spent on skipped cases.
    @Test func skippingTheFirstTwentyFiveSetsBringsTheNextOnesForward() {
        withStore { store, _ in
            var inputs: [StewardInput] = []
            for i in 0..<30 {
                let g = UUID()
                inputs.append(keeper("/Volumes/SanDisk/k\(i).mov", g))
                inputs.append(extra("/Volumes/SanDisk/c\(i).mov", g, bytes: Int64(100 - i) * GB))
            }
            let first = store.partition(build(inputs).cases).active.filter { $0.kind == .reclaimGroup }
            #expect(first.count == StewardCaseBuilder.maxCasesPerKind)
            first.forEach(store.skip)
            // The model hands the builder what was skipped (`snapshot`).
            #expect(store.snapshot().count == 25)
            let after = store.partition(build(inputs, skipped: store.snapshot()).cases)
            #expect(after.active.filter { $0.kind == .reclaimGroup }.count == 5, "the five sets behind the limit come forward")
            #expect(after.skipped.filter { $0.kind == .reclaimGroup }.count == 25, "…and the skipped ones can still be brought back")
            // A skipped set whose facts moved materially is not "skipped" to the limit either.
            var moved = inputs
            moved[1].sizeBytes *= 3
            let again = store.partition(build(moved, skipped: store.snapshot()).cases)
            #expect(again.active.filter { $0.kind == .reclaimGroup }.count == 6)
        }
    }

    /// QA F5: every duplicate check gives a set a new group id; the skip
    /// must follow the set (its keeper), not the number.
    @Test func aSkippedSetStaysSkippedWhenTheDuplicateCheckRenumbersItsGroup() throws {
        try withStoreThrowing { store, _ in
            let before = UUID(), after = UUID()
            var inputs = [keeper("/Volumes/SanDisk/k.mov", before), extra("/Volumes/SanDisk/c.mov", before)]
            let set = try #require(build(inputs).cases.first { $0.kind == .reclaimGroup })
            store.skip(set)
            for i in inputs.indices { inputs[i].duplicateGroupID = after }
            let again = try #require(build(inputs).cases.first { $0.kind == .reclaimGroup })
            #expect(again.id == set.id, "the case id moved with the group number")
            #expect(store.isSkipped(again))
            #expect(again.id == "dup:" + inputs[0].id.uuidString, "keyed by the keeper's record id")
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
    /// footage groups of 5, 20,000 junk rows in 40 clusters, and 57,000
    /// clips with a day-precise date — every one resolved by the Angel's
    /// derivation and labelled against 40 birthdays, one folder in forty
    /// carrying an event word. One build under 4 s in Debug — it runs off
    /// the main actor, once per debounced catalog change.
    @Test func hundredThousandRecordsBuildUnderBudget() {
        let drives = ["/Volumes/SanDisk", "/Volumes/LaCie", "/Volumes/X9", "/Volumes/Gone", "/Volumes/Extra"]
        let scaleVolumes = drives.map { AnalyzeVolumeFact(root: $0, isReachable: $0 != "/Volumes/Gone", isRetired: false) }
        let dupGroups = (0..<2_000).map { _ in UUID() }
        let footageGroups = (0..<3_000).map { _ in UUID() }
        let reasons = ["Very short (1.2s)", "Zero-byte file", "Avid render/precompute file", "System/hidden directory artifact",
                       "Filename suggests test/temp/sample content", "Zero duration", "File appears truncated (size << expected)",
                       "Screencast resolution (1920x1200), no audio"]
        let folderWords = ["xmas", "cape", "vacation", "bday", "tapes", "misc", "camera", "imports", "old", "new"]
        var inputs: [StewardInput] = []
        inputs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let folder = i % 40 < 4 ? "\(folderWords[i % 40]) \(i % 400)" : "folder\(i % 400)"
            var r = StewardInput(fullPath: "\(drives[i % 5])/\(folder)/clip\(i).mov", sizeBytes: Int64(1 + i % 9) * 100_000_000)
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
                r.bestDate = day(1990 + g % 30, 1 + g % 12, 1 + g % 28)
                r.userDate = String(format: "%04d-%02d-%02d", 1990 + g % 30, 1 + g % 12, 1 + g % 28)
            } else if i < 43_000 {
                r.junkScore = 5 + i % 4
                r.junkReasonKey = StewardCaseBuilder.junkReasonKey([reasons[i % reasons.count]])
            } else {
                // A camera's stamp, a different day for most.
                r.embeddedDate = day(1985 + (i / 7) % 35, 1 + (i / 3) % 12, 1 + i % 28)
                r.originModel = "Camcorder"
            }
            r.dupAnalyzedAt = i % 4 == 0 ? nil : Date(timeIntervalSince1970: Double(i))
            inputs.append(r)
        }
        let birthdays = (0..<40).map {
            FamilyBirthday(name: "Person \($0)", born: EventDay(year: 1950 + $0, month: 1 + $0 % 12, day: 1 + $0 % 28))
        }
        let start = ContinuousClock.now
        let q = StewardCaseBuilder.build(inputs: inputs, volumes: scaleVolumes,
                                         mountedRoots: ["/", "/Volumes/SanDisk", "/Volumes/LaCie", "/Volumes/X9", "/Volumes/Extra"],
                                         alsoCleanUpWorkingCopies: true,
                                         events: StewardEvents.context(coverage: .standard, birthdays: birthdays),
                                         calendar: utc, now: fixedNow)
        let elapsed = ContinuousClock.now - start
        #expect(q.isBuilt)
        #expect(q.count(of: .reclaimGroup) == StewardCaseBuilder.maxCasesPerKind)
        #expect(q.count(of: .reclaimDrive) == 5)
        #expect(q.count(of: .sameFootage) == StewardCaseBuilder.maxCasesPerKind)
        #expect(q.count(of: .junk) == StewardCaseBuilder.maxCasesPerKind)
        #expect(q.count(of: .event) == StewardEvents.maxEventCases, "far more events than the lane keeps")
        #expect(q.count(of: .unlabelledDay) == StewardCaseBuilder.maxCasesPerKind)
        #expect(q.placeableClips == 100_000 && q.placedClips > 50_000)
        #expect(q.cases.count <= StewardEvents.maxEventCases + 5 * StewardCaseBuilder.maxCasesPerKind,
                "the list is bounded whatever the catalog's size")
        #expect(q.cases.allSatisfy { $0.copies.count <= StewardCaseBuilder.maxCopiesPerCase && $0.recordIDs.count <= StewardCaseBuilder.maxIDsPerCase })
        #expect(q.cases.map(\.kind.lane) == q.cases.map(\.kind.lane).sorted(), "lane after lane")
        #expect(elapsed < PerformanceLane.debugCeiling(.milliseconds(4_000)),
                "steward build took \(elapsed) for 100k records — over the 4 s budget")
    }
}
