// PrunePlanScaleTests.swift
// The model half of the dry-run prune plan and the batch protection line
// (promote-and-prune stage 2, Rick 2026-09-12):
//
//   LOGIC  `archiveCopySnapshots()` maps the catalog faithfully: promote
//          link + fixity, inside-the-archive-root by REAL path, offline
//          (injected), pair members, versions vs repairs (with their
//          provenance, v3), human notes (machine text in `userNotes` is
//          NOT a note), stars / disposition / attestations, connected-
//          working volumes from the scan targets (the archive volume
//          never counts).
//   SCALE  `batchProtection` and `prunePlan` over 100k records × 5k
//          content groups, off-main, under a budget; the snapshot pass is
//          the only O(records) work and runs once per call.
//
// The archive root is a temp sandbox designation; `isOnline` is injected
// so no volume is ever touched.

import Foundation
import Testing
@testable import VideoScan

@Suite("Prune plan — model snapshots and scale", .serialized)
@MainActor
struct PrunePlanScaleTests {

    private let at = Date(timeIntervalSince1970: 1_757_700_000)

    private func rec(_ name: String, vol: String = "LaCie", hash: String = "", size: Int64 = 1_000) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name; r.fullPath = "/Volumes/\(vol)/\(name)"; r.directory = "/Volumes/\(vol)"
        r.scanContext.volumeName = vol; r.contentHash = hash; r.sizeBytes = size
        return r
    }

    @Test("snapshots map fixity, archive root, offline, pair, version/repair (+ provenance), note, marks and the working volumes")
    func snapshotsAreFaithful() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("snap")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)

        let source = rec("tape.mov", hash: "v1:t", size: 500)
        source.starRating = 2
        let archive = rec("tape_archive.mov", vol: "FamilyArchive", hash: "", size: 500)
        archive.fullPath = sb.archiveRoot.appendingPathComponent("30_Video/1990-1999/1992/1992-07-15_tape.mov").path
        archive.derivedFrom = source.id; archive.derivationKind = ArchivePromotion.derivationKind
        archive.archiveFixity = ArchiveFixity(digest: "d", verifiedAt: at, sizeBytes: 500)
        archive.starRating = 3; archive.mediaDisposition = .important
        let stray = rec("stray.mov", hash: "v1:t")
        stray.fullPath = sb.archiveRoot.appendingPathComponent("30_Video/stray.mov").path   // inside the root, no promote link
        let offline = rec("tape_old.mov", vol: "MyBook", hash: "v1:t")
        let pair = rec("tape.mxf", vol: "X9", hash: "v1:t"); pair.pairGroupID = UUID()
        let version = rec("tape_balanced.mov", vol: "Projects", hash: "v1:tb"); version.derivedFrom = source.id; version.derivationKind = "balanceAudio"
        let repair = rec("tape_fixed.mov", vol: "Projects", hash: "v1:tf"); repair.derivedFrom = source.id; repair.derivationKind = RebuildAudioFix.derivationKind
        let cleaned = rec("tape_cleaned.mov", vol: "Projects", hash: "v1:tc"); cleaned.derivedFrom = version.id; cleaned.cleanupRecipeID = "vhs-quick-clean"
        let noted = rec("tape_note.mov", vol: "X10", hash: "v1:t"); noted.userNotes = "  Ma's 80th  "
        noted.backupAttestations = [BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud", attestedAt: at)]
        let machineNoted = rec("tape_probe.mov", vol: "X10", hash: "v1:t")
        machineNoted.userNotes = "ffprobe: Unsupported codec with id 98314 for input stream 1"
        let purged = rec("gone.mov", hash: "v1:t"); purged.purgedAt = at
        model.records = [source, archive, stray, offline, pair, version, repair, cleaned, noted, machineNoted, purged]

        let snaps = model.archiveCopySnapshots { $0.volumeName != "MyBook" }
        let by = Dictionary(uniqueKeysWithValues: snaps.map { ($0.id, $0) })
        #expect(by[purged.id] == nil, "purged records are not snapshotted")
        let s = try #require(by[source.id])
        #expect(s.contentKey == "h:v1:t" && !s.isArchiveCopy && !s.isInsideArchiveRoot && s.isOnline && !s.isVersion && s.starRating == 2)
        #expect(s.derivedFrom == nil && s.derivationKind == nil)
        let a = try #require(by[archive.id])
        #expect(a.isArchiveCopy && a.fixityVerified && a.promotedFromID == source.id && a.contentKey == "" && a.disposition == .important)
        #expect(a.derivedFrom == source.id && a.derivationKind == ArchivePromotion.derivationKind)
        #expect(!a.volumeIsConnectedWorking, "the archive volume is never a working volume")
        let st = try #require(by[stray.id])
        #expect(st.isInsideArchiveRoot && !st.isArchiveCopy && !st.fixityVerified, "inside the real root by path, no fixity")
        #expect(by[offline.id]?.isOnline == false)
        #expect(by[pair.id]?.isPairMember == true)
        let v = try #require(by[version.id])
        #expect(v.isVersion && v.derivedFrom == source.id && v.derivationKind == "balanceAudio")
        #expect(by[repair.id]?.isVersion == false, "a repair is a candidate in its own right")
        let c = try #require(by[cleaned.id])
        #expect(c.isVersion && c.derivedFrom == version.id && c.derivationKind == "cleanup", "a cleanup output is tagged from its recipe")
        let n = try #require(by[noted.id])
        #expect(n.hasHumanNote && n.attestations.count == 1)
        #expect(by[machineNoted.id]?.hasHumanNote == false, "ffprobe text in userNotes is not a person's note")
        #expect(by[source.id]?.volumeIsConnectedWorking == true, "a /Volumes path with no scan target: working iff online")
        #expect(by[offline.id]?.volumeIsConnectedWorking == false)

        // The plan over that family: verified archive; stray + offline +
        // pair kept; the balanced version and its cleanup JOIN the family
        // by provenance (v3) and are checkable, unchecked; the noted copy
        // is checkable, unchecked; the machine-noted copy is a plain
        // candidate; the noted copy's cloud attestation covers the ★★★
        // bar; the offline MyBook and X10 copies already count as devices
        // → keeper not required; keep-one keeps the source; the plain
        // machine-noted copy is the default check.
        let plan = await model.prunePlan(for: [source.id], options: .init()) { $0.volumeName != "MyBook" }
        #expect(plan.families.count == 1)
        let f = try #require(plan.families.first)
        #expect(f.covered && f.level == .important)
        #expect(!f.keeperRequired)
        #expect(f.keeper?.id == source.id)
        #expect(f.trash.map(\.id) == [machineNoted.id])
        #expect(f.extraCount == 5, "source + machine-noted + balanced + cleaned + noted")
        #expect(f.archive.map(\.filename) == ["tape_archive.mov", "stray.mov"] && f.archiveVerified)
        #expect(!f.rows.contains { $0.id == archive.id || $0.id == stray.id }, "the archive side is never a row")
        let reasons = Dictionary(uniqueKeysWithValues: f.kept.map { ($0.copy.filename, $0.reason) })
        #expect(reasons["stray.mov"] == .insideArchiveRoot)
        #expect(reasons["tape_old.mov"] == .offline)
        #expect(reasons["tape.mxf"] == .pairMember)
        #expect(reasons["tape_note.mov"] == .humanNote)
        #expect(reasons["tape_archive.mov"] == .archiveCopy)
        #expect(reasons["tape_balanced.mov"] == .version, "the version joined its original's family")
        #expect(reasons["tape_cleaned.mov"] == .version, "two hops up")
        #expect(reasons["tape_fixed.mov"] == nil, "a repair has its own content key — a different family")
        let rows = Dictionary(uniqueKeysWithValues: f.rows.map { ($0.copy.filename, $0) })
        #expect(rows["tape_balanced.mov"]?.checkable == true && rows["tape_balanced.mov"]?.kind == .balanced)
        #expect(rows["tape_cleaned.mov"]?.kind == .cleaned)
        #expect(rows["tape.mov"]?.kind == .original && rows["tape_probe.mov"]?.kind == .duplicate)
        #expect(rows["tape_note.mov"]?.checkable == true && rows["tape_note.mov"]?.hasNote == true)
        // keep-one off → the source goes too (the bar is still met by MyBook + X10).
        let off = await model.prunePlan(for: [source.id], options: .init(keepOne: false)) { $0.volumeName != "MyBook" }
        #expect(off.trashCount == 2 && Set(off.trashFiles.map(\.id)) == [source.id, machineNoted.id])
        // The protection line from the same snapshots.
        let protection = await model.batchProtection(for: [source.id]) { $0.volumeName != "MyBook" }
        #expect(protection.archive == .verified)
        #expect(protection.workingCopyCount == 7, "source + offline + pair + balanced + cleaned + noted + machine-noted (the stray is an archive copy by root)")
        #expect(protection.displayLine.contains("MyBook offline"))
        #expect(protection.displayLine.hasSuffix("· cloud: iCloud · off-site: none"), "\(protection.displayLine)")
    }

    @Test("SCALE: batchProtection + prunePlan (with the might-be-copies pass) over 100k records × 5k content groups, off-main, under budget",
          .timeLimit(.minutes(2)))
    func scale100k() async {
        let volumes = ["LaCie", "Projects", "MyBook", "X9", "X10", "Movies"]
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        var batch: [UUID] = []
        batch.reserveCapacity(5_000)
        for g in 0..<5_000 {
            var firstID: UUID?
            for c in 0..<19 {
                let vol = volumes[(g + c) % volumes.count]
                let r = rec("g\(g)_c\(c).mov", vol: vol, hash: "v1:\(g)")
                r.starRating = 2
                if c == 0 {
                    firstID = r.id
                    batch.append(r.id)
                    if g % 3 == 0 {
                        r.backupAttestations = [BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud", attestedAt: at)]
                    }
                }
                records.append(r)
            }
            let copy = rec("g\(g)_archive.mov", vol: "FamilyArchive")
            copy.starRating = 3; copy.mediaDisposition = .important   // what registerPromotedCopy stamps
            copy.derivedFrom = firstID; copy.derivationKind = ArchivePromotion.derivationKind
            copy.archiveFixity = ArchiveFixity(digest: "d", verifiedAt: at, sizeBytes: 1)
            records.append(copy)
        }
        let model = VideoScanModel()
        model.records = records
        #expect(model.records.count == 100_000)
        let online: (VideoRecord) -> Bool = { $0.volumeName != "MyBook" }

        let clock = ContinuousClock()
        var protection = ProtectionSummary.empty
        let protElapsed = await clock.measure {
            protection = await model.batchProtection(for: batch, isOnline: online)
        }
        #expect(protection.familyCount == 5_000)
        #expect(protection.workingCopyCount == 95_000)
        #expect(protection.archive == .verified)
        #expect(protection.cloud == .mixed)
        #expect(protElapsed < .seconds(4), "batchProtection took \(protElapsed) for 100k records")

        var plan = PrunePlan.empty
        let planElapsed = await clock.measure {
            plan = await model.prunePlan(for: batch, options: .init(), isOnline: online)
        }
        #expect(plan.families.count == 5_000)
        #expect(plan.notCoveredCount == 5_000 - 1_667, "only every third family attested a cloud copy")
        #expect(plan.keeperVolumes.map(\.name).sorted() == ["LaCie", "Movies", "Projects", "X10", "X9"], "MyBook is offline — never a keeper volume")
        #expect(plan.trashCount > 0 && plan.trashCount < plan.extraCount)
        #expect(plan.relatedCount == 0, "every record is in a family — nothing is only name-related")
        #expect(planElapsed < .seconds(6), "prunePlan (families + might-be-copies pass) took \(planElapsed) for 100k records")
    }
}
