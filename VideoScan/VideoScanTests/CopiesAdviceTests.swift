// CopiesAdviceTests.swift
// "Copies & Advice…" (design §10): the advice rule table, the keeper choice
// (it must mirror DuplicateKeeperPolicy / DuplicateDetector.electKeeper),
// the freshness wording and the "why it was flagged" wording — on pure
// values, with the disk's answers injected. One end-to-end case runs the
// real projection + disk gather over synthetic files in a temp folder.
//
// (For Rick: each @Test is one row of the table; the disk is a value the
// test hands in, so nothing here depends on which drives are plugged in.)

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Builders

private enum CA {
    static let stamp = FileIdentityStamp(device: 1, inode: 1, size: 10, mtimeNs: 1, ctimeNs: 1, volumeUUID: nil)

    /// A copy with an election key built from (availability, precedence, marks).
    static func cand(_ name: String, volume: String = "test_X9", archive: Bool = false,
                     digest: String? = nil, hash: String = "", md5: String = "", size: Int64 = 10,
                     availability: Int = 2, precedence: Int = 30, marks: Int = 0,
                     id: UUID = UUID()) -> CopiesAdviceCandidate {
        let path = "/Volumes/\(volume)/test_\(name)"
        return CopiesAdviceCandidate(
            id: id, filename: "test_\(name)", fullPath: path, volume: volume, sizeBytes: size,
            isArchiveCopy: archive,
            archiveDigest: archive ? digest : nil,
            archiveCheckedAt: archive && digest != nil ? Date(timeIntervalSince1970: 1_790_000_000) : nil,
            contentFixity: archive ? nil : digest.map { ContentFixity(digest: $0, byteCount: size, stamp: stamp) },
            contentHash: hash, partialMD5: md5,
            electionKey: DuplicateKeeperPolicy.ElectionKey(availability: availability, precedence: precedence,
                                                           humanMetadata: marks, technical: 0, path: path))
    }

    static func input(this: CopiesAdviceCandidate, others: [CopiesAdviceCandidate], hold: String? = nil,
                      duplicates: CopiesFreshness = .asOf(Date(timeIntervalSince1970: 1_790_000_000))) -> CopiesAdviceInput {
        CopiesAdviceInput(header: .init(filename: this.filename, size: "10 bytes", codec: "DV", duration: "1:00"),
                          this: this, others: others, footage: [], hold: hold, duplicates: duplicates,
                          footageFreshness: .notComputed, flagged: [])
    }

    /// Every copy present, every stored digest current — unless told otherwise.
    static func disk(_ all: [CopiesAdviceCandidate], away: Set<UUID> = [], missing: Set<UUID> = [],
                     staleDigest: Set<UUID> = []) -> CopiesAdviceDisk {
        var d = CopiesAdviceDisk()
        for (i, c) in all.enumerated() {
            if away.contains(c.id) { d.presence[c.id] = .driveAway; continue }
            if missing.contains(c.id) { d.presence[c.id] = .fileMissing; continue }
            d.presence[c.id] = .present
            d.identity[c.id] = FileIdentityStamp(device: 7, inode: UInt64(100 + i), size: c.sizeBytes, mtimeNs: 1)
            if c.contentFixity != nil, !staleDigest.contains(c.id) { d.currentDigests.insert(c.id) }
        }
        return d
    }

    static func assess(_ this: CopiesAdviceCandidate, _ others: [CopiesAdviceCandidate],
                       away: Set<UUID> = [], missing: Set<UUID> = [], staleDigest: Set<UUID> = [],
                       hold: String? = nil, duplicates: CopiesFreshness = .asOf(Date(timeIntervalSince1970: 1_790_000_000)))
        -> CopiesAdvice {
        CopiesAdviceAssessor.assess(input(this: this, others: others, hold: hold, duplicates: duplicates),
                                    disk: disk([this] + others, away: away, missing: missing, staleDigest: staleDigest))
    }
}

// MARK: - The rule table

@Suite("Copies & Advice — the advice rule table")
struct CopiesAdviceRuleTableTests {

    @Test func theRuleOrderIsTheSpec_safetyFirst() {
        #expect(CopiesAdviceRule.allCases == [.archiveCopy, .held, .thisUnreachable, .onlyCopy,
                                              .decidingDriveAway, .thisIsKeeper, .sampleOnly, .safe])
    }

    @Test func safe_whenTheArchiveHoldsAVerifiedCopy_andSaysHowManyMore() {
        let this = CA.cand("a.mov", volume: "test_LaCie", digest: "aa", precedence: 99_997)
        let archive = CA.cand("a.mov", volume: "test_FamilyArchive", archive: true, digest: "aa", precedence: 1_000_000)
        let raid = CA.cand("a.mov", volume: "test_RAID", digest: "aa", precedence: 99_999)
        let ssd = CA.cand("a.mov", volume: "test_SanDisk", digest: "aa", precedence: 99_995)
        let a = CA.assess(this, [archive, raid, ssd])
        #expect(a.rule == .safe)
        #expect(a.verdict == .safe("the archive holds a verified copy, and 2 more copies exist"))
        #expect(a.verdict.sentence == "Safe to move to Trash — the archive holds a verified copy, and 2 more copies exist")
        #expect(a.verdict.tone == .safe && a.offersTrash)
        #expect(a.keeperID == archive.id)
        #expect(a.rows.first?.id == archive.id && a.rows.first?.fate == .keeps)
        #expect(a.rows[1].isThis && a.rows[1].fate == .canGo)
        #expect(a.copyCount == 4)
    }

    @Test func safe_withoutTheArchive_namesTheKeepersDrive() {
        let this = CA.cand("a.mov", volume: "test_SSD", digest: "aa", precedence: 10)
        let raid = CA.cand("a.mov", volume: "test_RAID", digest: "aa", precedence: 99_999)
        let a = CA.assess(this, [raid])
        #expect(a.verdict.sentence == "Safe to move to Trash — a verified copy stays on test_RAID")
    }

    @Test func archiveCopy_beatsSafe() {
        let this = CA.cand("a.mov", volume: "test_FamilyArchive", archive: true, digest: "aa", precedence: 1_000_000)
        let other = CA.cand("a.mov", volume: "test_RAID", digest: "aa", precedence: 99_999)
        let a = CA.assess(this, [other])
        #expect(a.rule == .archiveCopy)
        #expect(a.verdict.sentence == "Keep — this is the archive copy")
        #expect(!a.offersTrash)
    }

    @Test func onlyCopy_beatsSafe_andSaysWhenCopiesWereNeverChecked() {
        let this = CA.cand("a.mov", digest: "aa")
        let known = CA.assess(this, [])
        #expect(known.rule == .onlyCopy)
        #expect(known.verdict.sentence == "Keep — this is the only copy")
        #expect(!known.offersTrash)
        let unknown = CA.assess(this, [], duplicates: .notComputed)
        #expect(unknown.verdict == .keepOnlyCopy(known: false))
        #expect(unknown.verdict.sentence.hasPrefix("Keep — this is the only copy we know of"))
    }

    @Test func aDifferentFileInTheSameGroup_isNotACopy_soThisIsTheOnlyCopy() {
        let this = CA.cand("a.mov", digest: "aa")
        let lookalike = CA.cand("a.mov", volume: "test_RAID", digest: "bb", precedence: 99_999)
        let a = CA.assess(this, [lookalike])
        #expect(a.rule == .onlyCopy)
        #expect(a.sameFootage.map(\.id) == [lookalike.id], "listed under SAME FOOTAGE as a possible copy")
        #expect(a.sameFootage.first?.detail.contains("bytes differ") == true)
    }

    @Test func sampleOnly_isCheckFirst_neverSafe() {
        let this = CA.cand("a.mov", volume: "test_SSD", hash: "v1:x", precedence: 10)
        let raid = CA.cand("a.mov", volume: "test_RAID", hash: "v1:x", precedence: 99_999)
        let a = CA.assess(this, [raid])
        #expect(a.rule == .sampleOnly)
        #expect(a.verdict.sentence == "Check first — the copies match by sample only")
        #expect(a.verdict.tone == .attention && !a.offersTrash)
        #expect(a.rows.first { $0.id == raid.id }?.match == .sampled)
    }

    @Test func aStaleDigest_isOnlyASample() {
        let this = CA.cand("a.mov", volume: "test_SSD", digest: "aa", md5: "m", precedence: 10)
        let raid = CA.cand("a.mov", volume: "test_RAID", digest: "aa", md5: "m", precedence: 99_999)
        let a = CA.assess(this, [raid], staleDigest: [this.id])
        #expect(a.rule == .sampleOnly, "a digest that no longer describes the file proves nothing")
    }

    @Test func headAndTailHash_needsTheSameSize() {
        let this = CA.cand("a.mov", md5: "m", size: 10)
        let other = CA.cand("a.mov", volume: "test_RAID", md5: "m", size: 11, precedence: 99_999)
        #expect(CA.assess(this, [other]).rule == .onlyCopy)
    }

    @Test func offlineKeeper_isConnect() {
        // The better-ranked RAID copy is not connected: the live election
        // would keep THIS (online beats offline), but the decision waits for RAID.
        let this = CA.cand("a.mov", volume: "test_SSD", digest: "aa", precedence: 10)
        let raid = CA.cand("a.mov", volume: "test_RAID", digest: "aa", availability: 1, precedence: 99_999)
        let a = CA.assess(this, [raid], away: [raid.id])
        #expect(a.rule == .decidingDriveAway)
        #expect(a.verdict.sentence == "Connect test_RAID to decide")
        #expect(!a.offersTrash)
    }

    @Test func thisFilesDriveAway_isConnectThatDrive() {
        let this = CA.cand("a.mov", volume: "test_SSD", digest: "aa", availability: 1, precedence: 10)
        let raid = CA.cand("a.mov", volume: "test_RAID", digest: "aa", precedence: 99_999)
        let a = CA.assess(this, [raid], away: [this.id])
        #expect(a.verdict == .connect("test_SSD"))
    }

    @Test func thisFileMissing_isCheckFirst() {
        let this = CA.cand("a.mov", digest: "aa")
        let raid = CA.cand("a.mov", volume: "test_RAID", digest: "aa", precedence: 99_999)
        let a = CA.assess(this, [raid], missing: [this.id])
        #expect(a.verdict == .checkFirst(.notFound))
    }

    @Test func thisIsTheKeeper_isKeep_withTheElectionsReason() {
        let this = CA.cand("a.mov", volume: "test_RAID", digest: "aa", precedence: 99_999)
        let ssd = CA.cand("a.mov", volume: "test_SSD", digest: "aa", precedence: 10)
        let a = CA.assess(this, [ssd])
        #expect(a.rule == .thisIsKeeper)
        #expect(a.verdict.sentence.hasPrefix("Keep — this is the copy to keep."))
        #expect(a.keeperReason == "Its drive, test_RAID, comes first in your drive order.")
        #expect(a.rows.first?.isThis == true && a.rows.first?.fate == .keeps)
        #expect(!a.offersTrash)
    }

    @Test func aHeldFile_isKeep_beforeAnythingSafe() {
        let this = CA.cand("a.mov", volume: "test_SSD", digest: "aa", precedence: 10)
        let raid = CA.cand("a.mov", volume: "test_RAID", digest: "aa", precedence: 99_999)
        let a = CA.assess(this, [raid], hold: "lives on test_SSD, which you marked Read only")
        #expect(a.rule == .held)
        #expect(a.verdict.sentence == "Keep — this file lives on test_SSD, which you marked Read only")
        #expect(!a.offersTrash)
    }

    @Test func anotherNameForTheSameFile_isNotASecondCopy() {
        let this = CA.cand("a.mov", digest: "aa")
        let link = CA.cand("b.mov", volume: "test_RAID", digest: "aa", precedence: 99_999)
        var disk = CA.disk([this, link])
        disk.identity[link.id] = disk.identity[this.id]          // same device + inode
        let a = CopiesAdviceAssessor.assess(CA.input(this: this, others: [link]), disk: disk)
        #expect(a.rule == .onlyCopy, "a hard link of this file must never count as the keeper")
        #expect(a.notes.count == 1)
    }

    @Test func rowFates_keeperKeeps_archiveStays_sampleIsCheck_awayStays() {
        let this = CA.cand("a.mov", volume: "test_SSD", digest: "aa", precedence: 10)
        let raid = CA.cand("a.mov", volume: "test_RAID", digest: "aa", precedence: 99_999)
        let archive = CA.cand("a.mov", volume: "test_FamilyArchive", archive: true, digest: "aa",
                              availability: 1, precedence: 1_000_000)
        let sampled = CA.cand("a.mov", volume: "test_X10", hash: "v1:z", precedence: 20)
        var thisSampled = this
        thisSampled.contentHash = "v1:z"
        let a = CA.assess(thisSampled, [raid, archive, sampled], away: [archive.id])
        let fate = Dictionary(uniqueKeysWithValues: a.rows.map { ($0.id, $0.fate) })
        #expect(fate[raid.id] == .keeps)
        #expect(fate[archive.id] == .stays("archive copy"))
        #expect(fate[sampled.id] == .checkFirst)
    }

    @Test func everyVerdictHasOneOfTheFixedSentenceShapes() {
        let all: [CopiesAdviceVerdict] = [.safe("x"), .keepArchiveCopy, .keepHeld("x"), .keepOnlyCopy(known: true),
                                          .keepOnlyCopy(known: false), .keepKeeper("x"), .checkFirst(.sampleOnly),
                                          .checkFirst(.notFound), .connect("X")]
        for v in all {
            let s = v.sentence
            #expect(s.hasPrefix("Safe to move to Trash — ") || s.hasPrefix("Keep — ")
                    || s.hasPrefix("Check first — ") || (s.hasPrefix("Connect ") && s.hasSuffix(" to decide")), "\(s)")
            #expect(v.offersTrash == (v.tone == .safe))
        }
        #expect(all.filter(\.offersTrash).count == 1, "only Safe offers the Trash")
    }
}

// MARK: - Keeper mirrors the policy

@Suite("Copies & Advice — keeper mirrors DuplicateKeeperPolicy")
@MainActor
struct CopiesAdviceKeeperTests {

    private func record(_ path: String, stars: Int = 0) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.sizeBytes = 1_000
        r.starRating = stars
        return r
    }

    /// For every choice of "this", the card's keeper is the record
    /// DuplicateDetector.electKeeper picks under the same policy.
    @Test func keeperIsWhatTheDuplicateEngineWouldElect() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("copies_keeper")
        defer { sb.cleanup() }
        let m = MasterArchiveTestSupport.makeModel(sb)
        let recs = [record("/Volumes/test_SSD/test_a.mov"), record("/Volumes/test_RAID/test_a.mov"),
                    record("/Volumes/test_HDD/test_a.mov", stars: 3)]
        let policies = [
            DuplicateKeeperPolicy(precedence: ["test_RAID", "test_HDD", "test_SSD"]),
            DuplicateKeeperPolicy(precedence: ["test_SSD", "test_HDD", "test_RAID"]),
            DuplicateKeeperPolicy(precedence: []),          // marks decide: the starred HDD copy
            DuplicateKeeperPolicy(precedence: ["test_RAID", "test_HDD", "test_SSD"],
                                  facts: ["/Volumes/test_RAID": .init(isReachable: false)]),
        ]
        for policy in policies {
            let expected = try #require(DuplicateDetector.electKeeper(from: recs, policy: policy))
            for this in recs {
                let cands = recs.map { CopiesAdviceInput.candidate($0, policy: policy, model: m) }
                let thisCand = try #require(cands.first { $0.id == this.id })
                let others = cands.filter { $0.id != this.id }
                // The disk agrees with the policy's reachability.
                var disk = CopiesAdviceDisk()
                for c in cands { disk.presence[c.id] = c.electionKey.availability == 2 ? .present : .driveAway }
                let got = CopiesAdviceAssessor.elect(this: thisCand, copies: others, disk: disk).keeper
                #expect(got.id == expected.id, "policy \(policy.precedence) this=\(this.fullPath)")
            }
        }
    }

    @Test func aDriveTheDiskSaysIsAwayIsNeverElected() {
        let raid = CA.cand("a.mov", volume: "test_RAID", digest: "aa", precedence: 99_999)
        let ssd = CA.cand("a.mov", volume: "test_SSD", digest: "aa", precedence: 10)
        let disk = CA.disk([raid, ssd], away: [raid.id])
        #expect(CopiesAdviceAssessor.elect(this: ssd, copies: [raid], disk: disk).keeper.id == ssd.id)
    }
}

// MARK: - Freshness and "why flagged" wording

@Suite("Copies & Advice — freshness and why-flagged words")
struct CopiesAdviceWordsTests {

    @Test func freshnessNeverGuesses() {
        let d = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(CopiesFreshness.notComputed.line("Copies") == "Copies: not computed yet — Refresh")
        #expect(CopiesFreshness.asOf(d).line("Copies") == "Copies as of \(CopiesFreshness.when(d))")
        #expect(CopiesFreshness.outOfDate(d).line("Copies").hasSuffix("the drive order has changed since; Refresh"))
        #expect(CopiesFreshness.notComputed.needsRefresh && CopiesFreshness.outOfDate(d).needsRefresh)
        #expect(!CopiesFreshness.asOf(d).needsRefresh)
    }

    @Test func whyFlagged_saysEachSourceInPlainWords() {
        var f = CopiesFlagFacts()
        #expect(CopiesAdviceWhy.lines(f) == [CopiesAdviceWhy.nothing])
        f.disposition = .confirmedJunk
        f.junkReasons = ["very short"]
        f.duplicateDisposition = .extraCopy
        f.duplicateReasons = "hash+filename+duration"
        f.duplicateBestMatch = "test_a.mov"
        f.stewardLines = ["Tidy suggestions: Reclaim space — 3 copies"]
        let lines = CopiesAdviceWhy.lines(f)
        #expect(lines[0] == "You marked it as junk — very short")
        #expect(lines[1] == "Duplicate check: an extra copy of test_a.mov — matched on a sampled signature, name, length")
        #expect(lines[2] == "Tidy suggestions: Reclaim space — 3 copies")
    }

    @Test func trashOutcomeWords() {
        #expect(CopiesAdviceText.trashOutcome(succeeded: 1, alreadyMissing: 0, skippedOffline: 0, failed: 0).hasPrefix("Moved to the Trash"))
        #expect(CopiesAdviceText.trashOutcome(succeeded: 0, alreadyMissing: 0, skippedOffline: 1, failed: 0)
                == "Nothing was moved — its drive isn't connected.")
        #expect(CopiesAdviceText.trashOutcome(succeeded: 0, alreadyMissing: 0, skippedOffline: 0, failed: 0)
                .hasPrefix("Nothing was moved"))
    }
}

// MARK: - End to end over real (synthetic) files

@Suite("Copies & Advice — projection + disk over synthetic files")
@MainActor
struct CopiesAdviceEndToEndTests {

    private func fixity(_ url: URL) throws -> ContentFixity {
        let data = try Data(contentsOf: url)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return try #require(ContentFixity.captured(path: url.path, digest: hex, byteCount: Int64(data.count)))
    }

    @Test func twoVerifiedCopies_onePreferred_isSafeForTheOther_thenOnlyCopyWhenItIsGone() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("copies_e2e")
        defer { sb.cleanup() }
        let m = MasterArchiveTestSupport.makeModel(sb)
        let aURL = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_a.mov"), bytes: 4096, seed: 1)
        let bURL = sb.sources.appendingPathComponent("test_b.mov")
        try FileManager.default.copyItem(at: aURL, to: bURL)
        let a = MasterArchiveTestSupport.makeRecord(path: aURL.path)
        let b = MasterArchiveTestSupport.makeRecord(path: bURL.path, starRating: 3)   // b carries the marks → keeper
        let g = UUID()
        for r in [a, b] {
            r.duplicateGroupID = g
            r.dupAnalyzedAt = Date()
            r.contentFixity = try fixity(URL(fileURLWithPath: r.fullPath))
        }
        m.records = [a, b]

        let advice = try #require(await CopiesAdviceLoader.load(recordID: a.id, model: m))
        #expect(advice.rule == .safe, "\(advice.verdict.sentence)")
        #expect(advice.keeperID == b.id)
        #expect(advice.rows.allSatisfy { $0.presence == .present })
        #expect(advice.rows.first { $0.id == b.id }?.match == .verified)

        // The keeper's file changes on disk: its digest no longer describes it.
        try MasterArchiveTestSupport.writeBlob(at: bURL, bytes: 4096, seed: 2)
        let after = try #require(await CopiesAdviceLoader.load(recordID: a.id, model: m))
        #expect(!after.offersTrash, "a keeper whose bytes are no longer proven is never Safe")

        // The other copy is gone from the catalog: this is the only copy.
        b.purgedAt = Date()
        let alone = try #require(await CopiesAdviceLoader.load(recordID: a.id, model: m))
        #expect(alone.rule == .onlyCopy)
    }
}
