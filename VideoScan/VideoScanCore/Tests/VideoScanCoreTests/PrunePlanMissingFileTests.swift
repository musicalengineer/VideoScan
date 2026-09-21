// PrunePlanMissingFileTests.swift
// LOGIC for the missing-file rule in the prune plan (2026-09-21 — Rick:
// "'M4drive' was said 'not connected' in some cases which is weird. So I
// could only delete some videos."). The boot volume is named M4drive; the
// file behind the row had been moved or deleted outside the app. Two
// facts, not one: the VOLUME is online (`isOnline`), the FILE is not
// there (`fileExists == false`). The plan must:
//   - list the row, disabled, with "not on M4drive any more (moved or
//     deleted?)" — never "drive not connected";
//   - never count it as a copy: not a candidate, not an extra copy, not
//     a keeper, not a device for the bar, not a "remaining" copy in the
//     selection's verdict, not in the protection line, never a name-
//     related row;
//   - name it in the log line as "N missing (removable)" and expose the
//     ids the sheet's Remove-from-catalog acts on.
// SENSOR: a truly offline copy still says "drive not connected" and still
// counts as a device — offline is judged before missing.

import XCTest
@testable import VideoScanCore

final class PrunePlanMissingFileTests: XCTestCase {

    private func copy(_ name: String, vol: String, key: String = "h:v1:k", size: Int64 = 1_000,
                      archive: Bool = false, verified: Bool = false, online: Bool = true, exists: Bool = true,
                      pair: Bool = false, version: Bool = false, note: Bool = false, stars: Int = 0,
                      disposition: MediaDisposition = .unreviewed, attestations: [BackupAttestation] = [],
                      working: Bool = true, free: Int64? = 100, promotedFrom: UUID? = nil, id: UUID = UUID(),
                      derivedFrom: UUID? = nil, kind: String? = nil) -> ArchiveCopySnapshot {
        let path = vol == "M4drive" ? "/Users/rickb/Movies/\(name)" : "/Volumes/\(vol)/\(name)"
        return ArchiveCopySnapshot(id: id, filename: name, fullPath: path, volumeName: vol, sizeBytes: size,
                                   contentKey: key, promotedFromID: promotedFrom, isArchiveCopy: archive,
                                   fixityVerified: verified, isOnline: online, fileExists: exists,
                                   isPairMember: pair, isVersion: version, hasHumanNote: note, starRating: stars,
                                   disposition: disposition, attestations: attestations,
                                   volumeIsConnectedWorking: working, volumeFreeBytes: free,
                                   derivedFrom: derivedFrom, derivationKind: kind)
    }

    private func archiveCopy(key: String = "h:v1:k", promotedFrom: UUID? = nil, stars: Int = 3) -> ArchiveCopySnapshot {
        copy("archived.mov", vol: "FamilyArchive", key: key, archive: true, verified: true, stars: stars,
             disposition: .important, working: false, free: nil, promotedFrom: promotedFrom)
    }

    private func plan(_ family: [ArchiveCopySnapshot], keepOne: Bool = true, bar: ImportanceBar = .defaults) -> PrunePlan.Family {
        PrunePlan.compute(families: [family], options: .init(keepOne: keepOne, bar: bar)).families[0]
    }

    /// The ordinary bar: archive + 1 device, no cloud wanted.
    private var ordinaryBar: ImportanceBar {
        var bar = ImportanceBar.defaults
        bar.important = .init(extraDevices: 1, cloudOrOffsite: false)
        return bar
    }

    // MARK: The row

    func testAMissingFileIsListedDisabledWithTheMovedOrDeletedText_NeverDriveNotConnected() {
        let src = copy("Christmas2008.mov", vol: "CrucialX9")
        let arch = archiveCopy(promotedFrom: src.id)
        let gone = copy("Christmas2008.mov", vol: "M4drive", exists: false)
        let f = plan([src, arch, gone], bar: ordinaryBar)
        let row = f.rows.first { $0.id == gone.id }!
        XCTAssertEqual(row.role, .kept(.fileMissing))
        XCTAssertFalse(row.checkable)
        XCTAssertTrue(row.isMissingFile)
        XCTAssertEqual(row.reasonText, "not on M4drive any more (moved or deleted?)")
        XCTAssertNotEqual(row.reasonText, PrunePlan.KeepReason.offline.displayText)
        XCTAssertEqual(PrunePlan.KeepReason.fileMissing.displayText, "file not found — moved or deleted outside the app?")
        XCTAssertEqual(f.missingIDs, [gone.id])
        XCTAssertFalse(f.checkableIDs.contains(gone.id))
        XCTAssertFalse(f.defaultSelection.contains(gone.id), "never a default check")
    }

    func testAMissingRowWithNoVolumeNameStillReads() {
        let src = copy("a.mov", vol: "CrucialX9")
        let arch = archiveCopy(promotedFrom: src.id)
        var gone = copy("a.mov", vol: "M4drive", exists: false)
        gone.volumeName = ""
        let row = plan([src, arch, gone]).rows.first { $0.id == gone.id }!
        XCTAssertEqual(row.reasonText, "not on its drive any more (moved or deleted?)")
    }

    // MARK: Not a copy

    func testAMissingFileIsNotACandidateNorAnExtraCopyNorAKeeper() {
        let src = copy("Christmas2008.mov", vol: "CrucialX9", free: 10)
        let arch = archiveCopy(promotedFrom: src.id)
        // The missing copy sits on the volume with the MOST free space —
        // the keeper election must not see it.
        let gone = copy("Christmas2008.mov", vol: "M4drive", exists: false, free: 1_000)
        XCTAssertFalse(PrunePlan.isCandidate(gone))
        XCTAssertFalse(PrunePlan.isPlainCandidate(gone))
        XCTAssertTrue(gone.isMissingFile)
        let p = PrunePlan.compute(families: [[src, arch, gone]], options: .init(bar: ordinaryBar))
        let f = p.families[0]
        XCTAssertEqual(f.extraCount, 1, "only the source is an extra copy")
        XCTAssertEqual(f.extraBytes, 1_000)
        XCTAssertNotEqual(f.keeper?.id, gone.id)
        XCTAssertEqual(p.keeperVolumes.map(\.name), ["CrucialX9"], "M4drive holds no copy — never a keeper volume")
        XCTAssertEqual(f.kept.first { $0.copy.id == gone.id }?.reason, .fileMissing)
    }

    func testAMissingFileHoldsNoDeviceForTheBar_ButAnOfflineCopyStillDoes() {
        let src = copy("Christmas2008.mov", vol: "CrucialX9")
        let arch = archiveCopy(promotedFrom: src.id)
        let gone = copy("Christmas2008.mov", vol: "M4drive", exists: false)
        // Ordinary bar wants archive + 1 device. With only the source on
        // disk, keep-one OFF: the bar ITSELF must require the source as
        // the keeper (the missing file must not pass for the second
        // device) → nothing goes.
        let withMissing = plan([src, arch, gone], keepOne: false, bar: ordinaryBar)
        XCTAssertTrue(withMissing.keeperRequired, "the missing copy is not a device — the bar needs the source kept")
        XCTAssertEqual(withMissing.keeper?.id, src.id)
        XCTAssertTrue(withMissing.trash.isEmpty)
        XCTAssertFalse(withMissing.defaultSelection.contains(src.id))
        // SENSOR: the same shape with a truly OFFLINE copy needs no keeper
        // — an offline copy exists, on a drive that is not here — and the
        // source is the default check.
        let offline = copy("Christmas2008.mov", vol: "MyBook", online: false, working: false)
        let withOffline = plan([src, arch, offline], keepOne: false, bar: ordinaryBar)
        XCTAssertTrue(withOffline.covered && !withOffline.keeperRequired, "an offline copy still counts as a device")
        XCTAssertEqual(withOffline.trash.map(\.id), [src.id])
        XCTAssertEqual(withOffline.rows.first { $0.id == offline.id }?.role, .kept(.offline))
        XCTAssertEqual(withOffline.rows.first { $0.id == offline.id }?.reasonText, "drive not connected")
    }

    func testOfflineIsJudgedBeforeMissing() {
        // An unmounted volume cannot say whether the file exists: the row
        // says "drive not connected", never "moved or deleted".
        let src = copy("a.mov", vol: "CrucialX9")
        let arch = archiveCopy(promotedFrom: src.id)
        let off = copy("a.mov", vol: "MyBook", online: false, exists: false, working: false)
        XCTAssertFalse(off.isMissingFile)
        XCTAssertEqual(plan([src, arch, off]).rows.first { $0.id == off.id }?.role, .kept(.offline))
    }

    // MARK: The selection's verdict ("remaining copies")

    func testTheSelectionNeverCountsAMissingFileAsARemainingCopy() {
        let src = copy("Christmas2008.mov", vol: "CrucialX9")
        let arch = archiveCopy(promotedFrom: src.id)
        let dup = copy("Christmas2008.mov", vol: "Projects")
        let gone = copy("Christmas2008.mov", vol: "M4drive", exists: false)
        let f = plan([src, arch, dup, gone], keepOne: false, bar: ordinaryBar)
        // Check both real copies: only the archive remains — the missing
        // row is not a copy left behind.
        let s = f.selection([src.id, dup.id])
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.archiveOnlyFamilies, ["archived.mov"], "the missing file is not a remaining copy")
        XCTAssertEqual(s.overrideCount, 2, "no device remains — the missing file does not count as one")
        XCTAssertEqual(s.overrideShortfalls, ["★★★ / Important — needs 1 more device"])
        // Leave one real copy → covered, not archive-only.
        let t = f.selection([dup.id])
        XCTAssertEqual(t.overrideCount, 0)
        XCTAssertTrue(t.archiveOnlyFamilies.isEmpty)
    }

    // MARK: Protection, name-related, hashing

    func testTheProtectionLineDoesNotCountAMissingFile() {
        let src = copy("a.mov", vol: "CrucialX9")
        let arch = archiveCopy(promotedFrom: src.id)
        let gone = copy("a.mov", vol: "M4drive", exists: false)
        let p = ArchiveCopyFamilies.protection(families: [[src, arch, gone]])
        XCTAssertEqual(p.workingCopyCount, 1)
        XCTAssertEqual(p.workingVolumesOnline, ["CrucialX9"])
        XCTAssertTrue(p.workingVolumesOffline.isEmpty, "M4drive is neither online-with-a-copy nor offline")
    }

    func testAMissingFileIsNeverANameRelatedRowAndIsNotHashedToConfirm() {
        let src = copy("Christmas2008.mov", vol: "CrucialX9", key: "h:v1:x")
        let arch = archiveCopy(key: "h:v1:x", promotedFrom: src.id)
        let goneMember = copy("Christmas2008.mov", vol: "M4drive", key: "p:abc", exists: false)
        let goneRelated = copy("Christmas2008 copy.mov", vol: "M4drive", key: "", exists: false)
        let liveRelated = copy("Christmas2008 copy.mov", vol: "Projects", key: "")
        let snaps = [src, arch, goneMember, goneRelated, liveRelated]
        let fams = ArchiveCopyFamilies.group(batch: [src.id], snapshots: snaps)
        let related = ArchiveCopyFamilies.nameRelated(families: fams, snapshots: snaps, baseStem: { stem in
            var s = stem.lowercased()
            if s.hasSuffix(" copy") { s = String(s.dropLast(5)) }
            return s
        })
        XCTAssertEqual(related[0].members.map(\.id), [liveRelated.id], "a missing file is never a might-be-copy")
        let f = PrunePlan.compute(families: fams, related: related, options: .init()).families[0]
        XCTAssertFalse(f.unhashedMemberIDs.contains(goneMember.id), "nothing to hash — the file is not there")
    }

    // MARK: The log line and the batch-level ids

    func testTheLogLineNamesTheMissingRowsAsRemovable() {
        let src = copy("Christmas2008.mov", vol: "CrucialX9", key: "h:v1:x")
        let arch = archiveCopy(key: "h:v1:x", promotedFrom: src.id)
        let gone1 = copy("Christmas2008.mov", vol: "M4drive", key: "h:v1:x", exists: false)
        let gone2 = copy("Christmas2008 (1).mov", vol: "M4drive", key: "h:v1:x", exists: false)
        let offline = copy("Christmas2008.mov", vol: "LaCieWorkspace", key: "h:v1:x", online: false, working: false)
        var bar = ImportanceBar.defaults
        bar.important = .init(extraDevices: 0, cloudOrOffsite: false)
        let p = PrunePlan.compute(families: [[src, arch, gone1, gone2, offline]], options: .init(bar: bar))
        XCTAssertEqual(p.families[0].logLine,
                       "what-next: archived.mov — archive ✓ (1) · 4 copies on CrucialX9, M4drive, LaCieWorkspace (1 checkable, 1 offline, 2 missing (removable))")
        XCTAssertEqual(p.missingCount, 2)
        XCTAssertEqual(Set(p.missingIDs), [gone1.id, gone2.id])
        XCTAssertEqual(p.checkableCount, 1)
    }

    // MARK: checkingFiles — the stat pass

    func testCheckingFilesStatsOnlyTheOnlineWorkingCopies() {
        let src = copy("a.mov", vol: "CrucialX9")
        let arch = archiveCopy(promotedFrom: src.id)
        let off = copy("a.mov", vol: "MyBook", online: false, working: false)
        var purged = copy("a.mov", vol: "Projects")
        purged.isPurged = true
        var asked: [String] = []
        let out = ArchiveCopyFamilies.checkingFiles([[src, arch, off, purged]]) { path in
            asked.append(path)
            return false
        }
        XCTAssertEqual(asked, [src.fullPath], "the archive side, an offline volume and a purged row are never stat'd")
        let by = Dictionary(uniqueKeysWithValues: out[0].map { ($0.id, $0) })
        XCTAssertEqual(by[src.id]?.fileExists, false)
        XCTAssertEqual(by[arch.id]?.fileExists, true, "unknown stays true")
        XCTAssertEqual(by[off.id]?.fileExists, true)
        XCTAssertEqual(by[purged.id]?.fileExists, true)
        // Snapshot default: a snapshot that was never checked is "on disk".
        XCTAssertTrue(copy("b.mov", vol: "X").fileExists)
    }
}
