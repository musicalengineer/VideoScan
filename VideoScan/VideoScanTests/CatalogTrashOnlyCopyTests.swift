// CatalogTrashOnlyCopyTests.swift
// Tab-charter audit T3 (2026-10-11). The charter: Catalog ⌘⌫ Move to
// Trash is Finder-like, "but warns when the file is the only copy". The
// confirmation had no copy knowledge at all.
//
// Now the plan marks `onlyCopy` (CatalogKnownCopies: same bytes by
// partialMD5+size, contentHash+size or a whole-file digest; the copy must
// survive the move), the confirmation says "⚠︎ N of these are the only copy
// we know of.", and Move to Trash loses its Return key and turns
// destructive — a deliberate click, still allowed.
//
// Logic, words, a source sensor for the alert, and SCALE (100k records).

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Catalog Move to Trash — the only-copy warning (audit T3)", .serialized)
@MainActor
struct CatalogTrashOnlyCopyTests {

    /// A row; a non-empty `md5` also gives it a usable whole-file SHA-256
    /// fixity derived from it (since Codex #150 F3 a copy is known only by
    /// whole-file SHA-256 — the partial MD5 alone is never a copy). Each
    /// volume gets a stable UUID, each path its own inode.
    private func rec(_ path: String, md5: String, size: Int64 = 1_000) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path; r.filename = (path as NSString).lastPathComponent
        r.partialMD5 = md5; r.sizeBytes = size
        if !md5.isEmpty {
            r.contentFixity = ContentFixity(digest: Self.sha(md5), byteCount: size,
                                            stamp: Self.stamp(path, size: size))
        }
        return r
    }

    static func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A usable stored stamp: ctime known, bound to the path's volume UUID.
    static func stamp(_ path: String, size: Int64, inode: UInt64? = nil, device: UInt64 = 7,
                      volume: String?? = nil) -> FileIdentityStamp {
        let comps = (path as NSString).pathComponents
        let vol = comps.count > 2 && comps[1] == "Volumes" ? comps[2] : "boot"
        let uuid = volume ?? "00000000-0000-0000-0000-" + String(sha(vol).prefix(12)).uppercased()
        let ino = inode ?? (UInt64(sha(path).prefix(12), radix: 16) ?? 1)
        return FileIdentityStamp(device: device, inode: ino, size: size, mtimeNs: 1, ctimeNs: 1, volumeUUID: uuid)
    }

    private func model(_ records: [VideoRecord]) -> VideoScanModel {
        let m = VideoScanModel()
        m.records = records
        return m
    }

    private func plan(_ m: VideoScanModel, _ sel: [VideoRecord]) -> VideoScanModel.CatalogTrashPlan {
        m.catalogTrashPlan(for: sel, isOffline: { _ in false })
    }

    private func confirmation(_ p: VideoScanModel.CatalogTrashPlan, _ sel: [VideoRecord]) -> CatalogTrashConfirmation {
        CatalogTrashConfirmation(plan: p, sizes: Dictionary(uniqueKeysWithValues: sel.map { ($0.id, $0.sizeBytes) }))
    }

    @Test("one file, no other copy: warned, and Move to Trash is not the default")
    func soleFileIsWarned() {
        let only = rec("/Volumes/A/only.mov", md5: "m1")
        let m = model([only])
        let p = plan(m, [only])
        #expect(p.onlyCopy == [only.id])
        let c = confirmation(p, [only])
        #expect(c.detail == "You can put it back from the Trash until you empty it.\n\n⚠︎ This is the only copy we know of.")
        #expect(!c.moveIsDefault)
    }

    @Test("a same-bytes copy on another drive: no warning, Return still moves")
    func aCopyElsewhereIsNotWarned() {
        let a = rec("/Volumes/A/clip.mov", md5: "m1"), b = rec("/Volumes/B/clip.mov", md5: "m1")
        let m = model([a, b])
        let p = plan(m, [a])
        #expect(p.onlyCopy.isEmpty)
        let c = confirmation(p, [a])
        #expect(c.onlyCopyWarning == nil && c.moveIsDefault)
        #expect(c.detail == "You can put it back from the Trash until you empty it.")
    }

    @Test("both copies selected: nothing survives, both are the only copy")
    func bothCopiesLeaving() {
        let a = rec("/Volumes/A/clip.mov", md5: "m1"), b = rec("/Volumes/B/clip.mov", md5: "m1")
        let p = plan(model([a, b]), [a, b])
        #expect(Set(p.onlyCopy) == [a.id, b.id])
        #expect(confirmation(p, [a, b]).onlyCopyWarning == "⚠︎ 2 of these are the only copy we know of.")
    }

    @Test("three move, one is the only copy: '1 of these is'")
    func oneOfThree() {
        let a = rec("/Volumes/A/a.mov", md5: "a"), a2 = rec("/Volumes/B/a.mov", md5: "a")
        let b = rec("/Volumes/A/b.mov", md5: "b"), b2 = rec("/Volumes/B/b.mov", md5: "b")
        let c = rec("/Volumes/A/c.mov", md5: "c")
        let p = plan(model([a, a2, b, b2, c]), [a, b, c])
        #expect(p.onlyCopy == [c.id])
        #expect(confirmation(p, [a, b, c]).onlyCopyWarning == "⚠︎ 1 of these is the only copy we know of.")
    }

    @Test("not a copy: different size, removed, set aside, or the same path catalogued twice")
    func thingsThatAreNotACopy() {
        let target = rec("/Volumes/A/clip.mov", md5: "m1")
        let otherSize = rec("/Volumes/B/clip.mov", md5: "m1", size: 999)
        let purged = rec("/Volumes/C/clip.mov", md5: "m1"); purged.purgedAt = Date()
        let setAside = rec("/Volumes/D/clip.mov", md5: "m1"); setAside.setAsideReason = "test"
        let samePath = rec("/Volumes/A/clip.mov", md5: "m1")
        let p = plan(model([target, otherSize, purged, setAside, samePath]), [target])
        #expect(p.onlyCopy == [target.id])
    }

    @Test("fixity: a whole-file digest match is a copy even when the partial hashes differ")
    func fixityDigestIsACopy() {
        let target = rec("/Volumes/A/clip.mov", md5: "")
        target.contentFixity = ContentFixity(digest: Self.sha("abc"), byteCount: 1_000,
                                             stamp: Self.stamp(target.fullPath, size: 1_000), computedAt: Date())
        let archived = rec("/Volumes/Raid/Archive/clip.mov", md5: "")
        archived.archiveFixity = ArchiveFixity(digest: Self.sha("abc"), verifiedAt: Date(), sizeBytes: 1_000)
        #expect(plan(model([target, archived]), [target]).onlyCopy.isEmpty)
        let unknown = rec("/Volumes/A/no-keys.mov", md5: "")
        #expect(plan(model([unknown]), [unknown]).onlyCopy == [unknown.id], "no identity key = no known copy")
    }

    @Test("Codex #150 F3: the same partial MD5 with a DIFFERENT whole-file digest is not a copy")
    func conflictingFullDigestIsNotACopy() {
        let target = rec("/Volumes/A/clip.mov", md5: "m1")
        let impostor = rec("/Volumes/B/clip.mov", md5: "m1")
        impostor.contentFixity = ContentFixity(digest: Self.sha("other bytes"), byteCount: 1_000,
                                               stamp: Self.stamp(impostor.fullPath, size: 1_000))
        #expect(plan(model([target, impostor]), [target]).onlyCopy == [target.id])
        let md5Only = rec("/Volumes/C/clip.mov", md5: ""); md5Only.partialMD5 = "m1"
        #expect(plan(model([target, md5Only]), [target]).onlyCopy == [target.id], "a partial MD5 alone is not a copy")
    }

    @Test("QA M2: a copy superseded by a repair, or a skipped row, is not a surviving copy")
    func supersededAndSkippedAreNotSurvivors() {
        let target = rec("/Volumes/A/clip.mov", md5: "m1")
        let superseded = rec("/Volumes/B/clip.mov", md5: "m1"); superseded.supersededByID = UUID()
        let skipped = rec("/Volumes/C/clip.mov", md5: "m1")
        skipped.notes = VideoScanModel.formatSafelyRedundantNote(stamp: "s", source: skipped.fullPath,
                                                                 witnesses: ["/Volumes/D/x.mov"], totalWitnessCount: 1)
        #expect(plan(model([target, superseded, skipped]), [target]).onlyCopy == [target.id])
    }

    @Test("QA M2: the same inode on both fixity stamps (volume unproven) is the same file, not a copy")
    func sameDeviceAndInodeIsTheSameFile() {
        // One volume UUID for all three: the firmlink spelling shares the
        // target's inode on that volume (same file); the real copy does not.
        func stamped(_ path: String, inode: UInt64) -> VideoRecord {
            let r = rec(path, md5: "m1")
            let stamp = Self.stamp(path, size: 1_000, inode: inode, volume: "11111111-2222-3333-4444-555555555555")
            r.contentFixity = ContentFixity(digest: Self.sha("abc"), byteCount: 1_000, stamp: stamp)
            return r
        }
        let target = stamped("/Volumes/A/clip.mov", inode: 42)
        let firmlink = stamped("/System/Volumes/Data/Volumes/A/clip.mov", inode: 42)
        #expect(plan(model([target, firmlink]), [target]).onlyCopy == [target.id])
        let realCopy = stamped("/Volumes/B/clip.mov", inode: 43)
        #expect(plan(model([target, realCopy]), [target]).onlyCopy.isEmpty)
    }

    /// Nightly 2026-10-12 (FixityStampVolumeIdentityTests sensor): the
    /// stamps are STORED, and st_dev is handed out per mount. The same file
    /// stamped before and after a remount differs only in device number —
    /// it must still be the same file, so the only-copy warning fires.
    @Test("REMOUNT: stored stamps differing only in device number are still the same file — warned")
    func remountedStampsAreStillTheSameFile() {
        func stamped(_ path: String, device: UInt64, inode: UInt64, volume: String?) -> VideoRecord {
            let r = rec(path, md5: "m1")
            let stamp = FileIdentityStamp(device: device, inode: inode, size: 1_000, mtimeNs: 1, ctimeNs: 1,
                                          volumeUUID: volume)
            r.contentFixity = ContentFixity(digest: Self.sha("abc"), byteCount: 1_000, stamp: stamp)
            return r
        }
        let vol = "11111111-2222-3333-4444-555555555555"
        let other = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        // Same volume UUID + inode, new st_dev after a replug: one file, two spellings.
        let target = stamped("/Volumes/A/clip.mov", device: 16_777_230, inode: 42, volume: vol)
        let remounted = stamped("/System/Volumes/Data/Volumes/A/clip.mov", device: 16_777_252, inode: 42, volume: vol)
        #expect(plan(model([target, remounted]), [target]).onlyCopy == [target.id])
        // Pre-UUID stamps: the volume is unproven, so a matching inode is
        // never counted as a copy, whatever the device numbers say.
        let legacyTarget = stamped("/Volumes/A/clip.mov", device: 5, inode: 42, volume: nil)
        let legacyAlias = stamped("/Volumes/A/Links/clip-hardlink.mov", device: 9, inode: 42, volume: nil)
        #expect(plan(model([legacyTarget, legacyAlias]), [legacyTarget]).onlyCopy == [legacyTarget.id])
        // Different volume UUIDs: a real copy, even when a reused st_dev
        // and the inode both collide.
        let copy = stamped("/Volumes/B/clip.mov", device: 16_777_230, inode: 42, volume: other)
        #expect(plan(model([target, copy]), [target]).onlyCopy.isEmpty)
    }

    @Test("QA m3/m4 sensor: archive copies by link or digest only; Cancel starts focused when warned")
    func archiveLegAndFocusSensor() throws {
        let trash = try SourceTree.appCode(named: "VideoScanModel+TrashSelection.swift")
        let start = try #require(trash.range(of: "func catalogOnlyCopyIDs("))
        let end = try #require(trash.range(of: "nonisolated static func isKnownCopySurvivor(",
                                           range: start.upperBound..<trash.endIndex))
        let body = trash[start.upperBound..<end.lowerBound]
        // Codex #150 F3: archive copies count only by their read-back
        // SHA-256 through the same survivor rule (retired drives too) —
        // no separate archive leg, never the promotion index's scored match.
        #expect(!body.contains("archivedCopy(of:") && !body.contains("masterArchiveCopy(of:"))
        #expect(body.contains("isKnownCopySurvivor("))
        let table = try SourceTree.appCode(named: "CatalogContent+Table.swift")
        #expect(table.contains("alert.window.initialFirstResponder = cancel"))
    }

    @Test("rows the plan refuses never count toward the warning")
    func refusedRowsAreNotCounted() {
        let paired = rec("/Volumes/A/v.mxf", md5: "p"); paired.pairGroupID = UUID()
        let p = plan(model([paired]), [paired])
        #expect(p.toTrash.isEmpty && p.onlyCopy.isEmpty)
    }

    @Test("sensor: the alert takes Return off Move to Trash and marks it destructive when warned")
    func alertSensor() throws {
        let table = try SourceTree.appCode(named: "CatalogContent+Table.swift")
        let start = try #require(table.range(of: "func confirmThenTrash("))
        let end = try #require(table.range(of: "func reportDeleteResult(", range: start.upperBound..<table.endIndex))
        let door = table[start.upperBound..<end.lowerBound]
        let planAt = try #require(door.range(of: "model.catalogTrashPlan(for: targets)"))
        let alertAt = try #require(door.range(of: "NSAlert()"))
        #expect(planAt.lowerBound < alertAt.lowerBound, "the count is computed before the alert is shown")
        #expect(door.contains("if !confirmation.moveIsDefault {"))
        #expect(door.contains("move.keyEquivalent = \"\""))
        #expect(door.contains("move.hasDestructiveAction = true"))
    }

    @Test("SCALE: 100k-record catalog, 1,000 selected — the plan's copy check stays within budget")
    func hundredThousand() {
        var all: [VideoRecord] = []
        all.reserveCapacity(100_000)
        for i in 0..<100_000 {
            all.append(rec("/Volumes/S/\(i / 1000)/clip_\(i).mov", md5: "m\(i % 99_500)", size: 10_000))
        }
        // Rows 0..<500 share a hash with rows 99_500..<100_000 (a copy each);
        // rows 500..<1000 are unique.
        let selection = Array(all[0..<1_000])
        let m = model(all)
        let t0 = Date()
        let p = plan(m, selection)
        let took = -t0.timeIntervalSinceNow
        #expect(p.toTrash.count == 1_000)
        #expect(p.onlyCopy.count == 500)
        #expect(Set(p.onlyCopy) == Set(selection[500..<1_000].map(\.id)))
        // Debug, M4 Max, 2026-10-11: the whole test (building 100k rows
        // included) took 0.15 s; the budget for the plan alone is 1 s.
        #expect(took < 1.0, "only-copy check over 100k records took \(took) s")
    }
}
