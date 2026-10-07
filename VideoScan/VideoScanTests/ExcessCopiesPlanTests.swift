// ExcessCopiesPlanTests.swift
// The pure planner of "Delete excess copies", Tier 1
// (docs/design/delete_excess_copies_2026_10_06.md, C05 amendments, Rick's
// decisions 2026-10-07). LOGIC dimension: nomination (digest vs sampled),
// every keep rule leaves the copy alone with its words, Rick's
// longer-than-master rule flags and never offers, an unknown length is
// left alone, a drive that mirrors the archive's folders is refused as a
// whole, and the "archive will be the only copy" fact the dialog states.
// Synthetic values only — no file, no model, no preferences.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Excess copies — the plan")
struct ExcessCopiesPlanTests {

    static let digest = "aa11"
    static let v1 = "v1:test-excess"

    /// An archived FFV1 master (1 h) and its archived access file (1 h, the
    /// bytes a copy matches), one lineage root.
    struct Archive {
        let master: ExcessCopySnapshot
        let access: ExcessCopySnapshot
        var all: [ExcessCopySnapshot] { [master, access] }
    }

    static func archive(masterSeconds: Double = 3_600, accessSeconds: Double = 3_600) -> Archive {
        let root = UUID()
        let master = ExcessCopySnapshot(filename: "test_item.vs.preserve.mkv",
                                        fullPath: "/Volumes/FamilyArchive/Breen/30_Video/1995/test_item.vs.preserve.mkv",
                                        volumeName: "FamilyArchive", sizeBytes: 9_000, durationSeconds: masterSeconds,
                                        isArchiveSide: true, archiveDigest: "ffff", isPreservationMaster: true,
                                        archiveRelPath: "/30_Video/1995/test_item.vs.preserve.mkv", derivedFrom: root)
        let access = ExcessCopySnapshot(filename: "test_item.mov",
                                        fullPath: "/Volumes/FamilyArchive/Breen/30_Video/1995/test_item.mov",
                                        volumeName: "FamilyArchive", sizeBytes: 4_000, durationSeconds: accessSeconds,
                                        contentHash: v1, isArchiveSide: true, archiveDigest: digest,
                                        archiveVerifiedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                        archiveRelPath: "/30_Video/1995/test_item.mov", derivedFrom: root)
        return Archive(master: master, access: access)
    }

    static func copy(_ name: String = "test_copy.mov", vol: String = "MediaExpansion", seconds: Double = 3_600,
                     digest: String? = Self.digest, hash: String = "", size: Int64 = 4_000) -> ExcessCopySnapshot {
        ExcessCopySnapshot(filename: name, fullPath: "/Volumes/\(vol)/work/\(name)", volumeName: vol,
                           sizeBytes: size, durationSeconds: seconds, contentHash: hash, wholeDigest: digest)
    }

    // MARK: Nomination

    @Test("a stored whole digest nominates as exact; a v1 hash + size as sampled; anything else is not a copy")
    func nomination() {
        let a = Self.archive()
        let exact = Self.copy("test_exact.mov")
        let sampled = Self.copy("test_sampled.mov", digest: nil, hash: Self.v1)
        let wrongSize = Self.copy("test_size.mov", digest: nil, hash: Self.v1, size: 3_999)
        let other = Self.copy("test_other.mov", digest: "bb22")
        let plan = ExcessCopiesPlan.compute(a.all + [exact, sampled, wrongSize, other])
        #expect(plan.items.count == 1)
        let item = plan.items[0]
        #expect(Set(item.offered.map(\.id)) == [exact.id, sampled.id])
        #expect(item.offered.first { $0.id == exact.id }?.proof == .digest)
        #expect(item.offered.first { $0.id == sampled.id }?.proof == .sampled)
        #expect(item.offered.allSatisfy { $0.archiveID == a.access.id }, "read against the archived file it matches")
        #expect(item.master.id == a.master.id, "the item's master is the FFV1 preservation file")
        #expect(plan.sampledCount == 1)
    }

    @Test("an archived file with no verified digest nominates nothing; purged and archive-side records are never offered")
    func unverifiedArchiveAndArchiveSide() {
        var a = Self.archive()
        var unverified = a.access
        unverified.archiveDigest = nil
        #expect(ExcessCopiesPlan.compute([a.master, unverified, Self.copy()]).offeredCount == 0)
        var purged = Self.copy("test_purged.mov"); purged.isPurged = true
        var inside = Self.copy("test_inside.mov"); inside.isArchiveSide = true
        a = Self.archive()
        let plan = ExcessCopiesPlan.compute(a.all + [purged, inside])
        #expect(plan.offeredCount == 0 && plan.leftAloneCount == 0)
    }

    // MARK: Keep rules — each leaves the copy alone, with its words

    @Test("every keep rule leaves the copy alone and says why",
          arguments: ExcessCopiesPlanTests.keepRuleCases)
    func keepRule(_ c: KeepRuleCase) {
        let a = Self.archive()
        var s = Self.copy("test_rule.mov")
        c.apply(&s)
        let plan = ExcessCopiesPlan.compute(a.all + [s])
        #expect(plan.offeredCount == 0, "\(c.name) must never be offered")
        #expect(plan.items.first?.leftAlone.first?.reason == c.reason, "\(c.name)")
    }

    struct KeepRuleCase: CustomTestStringConvertible, Sendable {
        let name: String
        let reason: String
        let apply: @Sendable (inout ExcessCopySnapshot) -> Void
        var testDescription: String { name }
    }

    static let keepRuleCases: [KeepRuleCase] = [
        .init(name: "archive backup drive", reason: ExcessCopiesPlan.backupDriveReason) { $0.isOnArchiveBackupDrive = true },
        .init(name: "read-only drive (the one gate)", reason: "lives on SanDisk, which you marked Read only") {
            $0.gateRefusal = "lives on SanDisk, which you marked Read only"
        },
        .init(name: "network mount", reason: ExcessCopiesPlan.networkReason) { $0.isNetworkMount = true },
        .init(name: "offline drive", reason: ExcessCopiesPlan.offlineReason) { $0.isOnline = false },
        .init(name: "A/V pair half", reason: ExcessCopiesPlan.pairReason) { $0.isPairMember = true },
        .init(name: "Archive Angel hold", reason: ExcessCopiesPlan.angelReason) { $0.heldByAngel = true },
        .init(name: "Rick's stars ≥ 4", reason: "you rated it 4 stars") { $0.starRating = 4 },
        .init(name: "Rick's Keep tag", reason: "you tagged it Keep") { $0.tags = ["Gold", "keep"] },
        .init(name: "Rick's Keep in the lane", reason: "you chose Keep for it") { $0.keptInLane = true },
    ]

    // MARK: QA 2026-10-07 (FIX-FIRST)

    @Test("QA MAJOR 2: a sampled-only or archive-refused copy is not a survivor; a digest-proven Read-only copy is")
    func unprovenSurvivorDoesNotCount() {
        let a = Self.archive()
        let goes = Self.copy("test_goes.mov")
        var sampledStays = Self.copy("test_sampled_stays.mov", vol: "SanDisk", digest: nil, hash: Self.v1)
        sampledStays.tags = ["Keep"]
        let p1 = ExcessCopiesPlan.compute(a.all + [goes, sampledStays]).items[0]
        #expect(p1.survivors(of: a.access.id).isEmpty, "a sampled hash proves nothing stays")
        #expect(p1.leavesArchiveOnly, "so the dialog must say ONLY copy")
        var archiveSpelling = Self.copy("test_firmlink.mov", vol: "FamilyArchive")
        archiveSpelling.gateRefusal = "lives in the Master Archive, which only archive actions may change"
        archiveSpelling.gateRefusesAsArchive = true
        let p2 = ExcessCopiesPlan.compute(a.all + [goes, archiveSpelling]).items[0]
        #expect(p2.survivors(of: a.access.id).isEmpty, "the archive file under another spelling is not a copy outside it")
        #expect(p2.leavesArchiveOnly)
        var readOnly = Self.copy("test_ro.mov", vol: "SanDisk")
        readOnly.gateRefusal = "lives on SanDisk, which you marked Read only"
        let p3 = ExcessCopiesPlan.compute(a.all + [goes, readOnly]).items[0]
        #expect(p3.survivors(of: a.access.id).map(\.id) == [readOnly.id], "a proven copy on a Read-only drive stays")
        #expect(!p3.leavesArchiveOnly)
    }

    @Test("QA MINOR 3: length is judged against the master even when its digest is unverified — and then nothing goes")
    func longerGuardWithUnverifiedMaster() {
        let a = Self.archive(masterSeconds: 3_600, accessSeconds: 7_200)
        var master = a.master
        master.archiveDigest = nil
        let long = Self.copy("test_long.mov", seconds: 7_200)
        let plan = ExcessCopiesPlan.compute([master, a.access, long])
        #expect(!plan.offeredIDs.contains(long.id), "a copy longer than the master is never offered")
        #expect(plan.items.first?.master.id == master.id, "the unverified FFV1 is still the item's master")
        #expect(plan.offeredCount == 0, "an unverified master: hold rather than guess")
    }

    @Test("★★★ alone is not a hold — Promote sets it on every promotion source")
    func threeStarsSetByPromoteIsNotAHold() {
        #expect(ExcessCopiesPlan.personHold(starRating: 3, tags: [], keptInLane: false) == nil)
        let a = Self.archive()
        var s = Self.copy("test_promoted_source.mov")
        s.starRating = 3
        #expect(ExcessCopiesPlan.compute(a.all + [s]).offeredIDs == [s.id])
    }

    @Test("an Archive backup drive outranks the gate's own wording")
    func backupWordingFirst() {
        var s = Self.copy()
        s.isOnArchiveBackupDrive = true
        s.gateRefusal = "lives on Backup, which you marked Read only"
        #expect(ExcessCopiesPlan.keepReason(s, backupLike: []) == ExcessCopiesPlan.backupDriveReason)
    }

    // MARK: Rick's decision 2 — longer than the master is never offered

    @Test("a copy longer than the archive master is FLAGGED, never offered — whatever its bytes say")
    func longerThanMasterIsFlagged() {
        // The archived access file is 2 h but the FFV1 master is 1 h: a
        // byte copy of the access file is longer than the master.
        let a = Self.archive(masterSeconds: 3_600, accessSeconds: 7_200)
        let long = Self.copy("test_long.mov", seconds: 7_200)
        let plan = ExcessCopiesPlan.compute(a.all + [long])
        #expect(plan.offeredCount == 0)
        #expect(plan.longerCount == 1 && plan.items[0].longer.map(\.id) == [long.id])
        #expect(ExcessCopiesPlan.longerFlag.contains("LONGER than the archive master"))
        #expect(!plan.offeredIDs.contains(long.id))
    }

    @Test("within the container tolerance is offered; past it is flagged; an unknown length is left alone")
    func toleranceAndUnknown() {
        #expect(ExcessCopiesPlan.lengthVerdict(copy: 3_600.9, master: 3_600) == .fits)
        #expect(ExcessCopiesPlan.lengthVerdict(copy: 3_601.5, master: 3_600) == .longer)
        #expect(ExcessCopiesPlan.lengthVerdict(copy: 1_800, master: 3_600) == .fits, "shorter loses nothing")
        #expect(ExcessCopiesPlan.lengthVerdict(copy: 0, master: 3_600) == .unknown)
        #expect(ExcessCopiesPlan.lengthVerdict(copy: 3_600, master: 0) == .unknown)
        let a = Self.archive()
        let unknown = Self.copy("test_unknown.mov", seconds: 0)
        let plan = ExcessCopiesPlan.compute(a.all + [unknown])
        #expect(plan.offeredCount == 0)
        #expect(plan.items[0].leftAlone.first?.reason == ExcessCopiesPlan.unknownLengthReason)
    }

    // MARK: C05 amendment 3 — a drive that mirrors the archive is refused whole

    @Test("a drive whose matches sit at the archive's own paths is refused as a whole, until it is marked")
    func backupLikeDriveRefusedWhole() {
        let a = Self.archive()
        var mirrored = Self.copy("test_item.mov", vol: "OffsiteBackup")
        mirrored.fullPath = "/Volumes/OffsiteBackup/Breen/30_Video/1995/test_item.mov"
        var loose = Self.copy("test_loose.mov", vol: "OffsiteBackup")
        loose.fullPath = "/Volumes/OffsiteBackup/misc/test_loose.mov"
        let workspace = Self.copy("test_ws.mov", vol: "MediaExpansion")
        let plan = ExcessCopiesPlan.compute(a.all + [mirrored, loose, workspace])
        #expect(plan.backupLikeVolumes == ["OffsiteBackup"])
        #expect(plan.offeredIDs == [workspace.id], "only the workspace copy is offered")
        let reasons = plan.items[0].leftAlone.map(\.reason)
        #expect(reasons.count == 2 && reasons.allSatisfy { $0 == ExcessCopiesPlan.backupLikeReason })
        #expect(!ExcessCopiesPlan.mirrorsArchivePath("/Volumes/X/test_item.mov", relPath: "/test_item.mov"),
                "a bare filename never counts as mirroring")
    }

    // MARK: The dialog's facts

    @Test("leavesArchiveOnly is true only when no connected copy stays outside the archive")
    func archiveOnlyFact() {
        let a = Self.archive()
        let goes = Self.copy("test_goes.mov")
        #expect(ExcessCopiesPlan.compute(a.all + [goes]).items[0].leavesArchiveOnly)
        var stays = Self.copy("test_stays.mov", vol: "SanDisk")
        stays.gateRefusal = "lives on SanDisk, which you marked Read only"
        let withSurvivor = ExcessCopiesPlan.compute(a.all + [goes, stays]).items[0]
        #expect(!withSurvivor.leavesArchiveOnly)
        #expect(withSurvivor.survivors(of: a.access.id).map(\.id) == [stays.id])
        var away = Self.copy("test_away.mov", vol: "MyBook"); away.isOnline = false
        let offlineOnly = ExcessCopiesPlan.compute(a.all + [goes, away]).items[0]
        #expect(offlineOnly.leavesArchiveOnly, "an offline copy cannot be counted on")
    }
}
