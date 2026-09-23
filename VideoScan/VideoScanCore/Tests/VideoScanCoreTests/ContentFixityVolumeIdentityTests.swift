// ContentFixityVolumeIdentityTests.swift
// The 2026-09-23 volume-identity rule for FileIdentityStamp / ContentFixity
// (see the ContentFixity.swift header). Positive: a remount (new st_dev,
// same volume UUID) keeps a digest current. Negative — every one must stay
// STALE: a different disk at the same path, inode reuse, clone, restore,
// rename-replace, same-size rewrite with mtime put back, UUID not
// resolvable now. Old-stamp upgrade rule, Codable compatibility, the
// task-local resolver seam (isolation), and a 100k scale budget.

import Darwin
import Foundation
import Testing
import VideoScanCore

private let uuidA = "84661FE3-C826-4B3B-A550-59BF9FEE77BD"
private let uuidB = "0978904A-3D3C-4546-BC51-5A53F32BCB23"

private func stamp(dev: UInt64 = 16_777_255, ino: UInt64 = 1_915_518, size: Int64 = 660_299_659,
                   mtime: Int64 = 1_275_630_050_000_000_000, ctime: Int64 = 1_786_994_248_712_435_423,
                   uuid: String? = uuidA) -> FileIdentityStamp {
    FileIdentityStamp(device: dev, inode: ino, size: size, mtimeNs: mtime, ctimeNs: ctime, volumeUUID: uuid)
}

private func fixity(_ s: FileIdentityStamp) -> ContentFixity {
    ContentFixity(digest: "7a4f16fd", byteCount: s.size, stamp: s)
}

/// A scratch directory on the boot volume, removed by the caller.
private func scratch(_ tag: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fixity-volid-\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("ContentFixity volume identity — comparison rule")
struct ContentFixityVolumeIdentityRuleTests {

    @Test func remountSameVolumeNewDeviceIsFresh() {
        let stored = stamp()
        let now = stamp(dev: 16_777_249)            // LaCieWorkspace after the 9/23 remount
        #expect(fixity(stored).describesFileNow(now))
        #expect(fixity(stored).stampMatches(now))
        #expect(stored.describesSameFile(now: now))
    }

    /// Same disk mounted at a different PATH: the stat follows the
    /// record's (migrated) path; the comparison itself never sees a path.
    @Test func sameDiskAtAnotherMountPointIsFresh() {
        #expect(fixity(stamp()).describesFileNow(stamp(dev: 99)))
    }

    /// A different disk at the same path — even one handed the SAME st_dev
    /// (device numbers are reused across disks, measured 2026-09-23) and
    /// holding a file with the same inode, size and times — is stale.
    @Test func differentDiskSamePathIsStaleEvenWithAReusedDeviceNumber() {
        let stored = stamp()
        #expect(!fixity(stored).describesFileNow(stamp(uuid: uuidB)))
        #expect(!fixity(stored).describesFileNow(stamp(dev: 1, uuid: uuidB)))
        #expect(!fixity(stored).stampMatches(stamp(uuid: uuidB)))
    }

    @Test func uuidNotResolvableNowIsStaleEvenOnTheSameDevice() {
        #expect(!fixity(stamp()).describesFileNow(stamp(uuid: nil)))
        #expect(!fixity(stamp()).stampMatches(stamp(uuid: nil)))
    }

    /// APFS reuses inode numbers after a delete; the new file's size,
    /// mtime or ctime give it away. Each field alone must refuse.
    @Test func inodeReuseOrAnyChangedFieldIsStale() {
        let f = fixity(stamp())
        #expect(!f.describesFileNow(stamp(dev: 7, ctime: 1_786_994_248_712_435_424)))
        #expect(!f.describesFileNow(stamp(dev: 7, mtime: 1_275_630_050_000_000_001)))
        #expect(!f.describesFileNow(stamp(dev: 7, size: 660_299_658)))
        #expect(!f.describesFileNow(stamp(dev: 7, ino: 1_915_519)))
        #expect(!f.describesFileNow(nil))
    }

    @Test func preCtimeStampNeverVerifiesEvenWithAUUID() {
        let old = stamp(ctime: FileIdentityStamp.unknownCtime)
        #expect(!fixity(old).describesFileNow(old))
        #expect(!fixity(old).isUsableForVerification)
    }

    /// A stamp WITHOUT a UUID keeps exactly the pre-fix rule: device must
    /// match. Nothing old becomes fresh by the comparison alone.
    @Test func legacyStampKeepsTheDeviceRule() {
        let legacy = stamp(uuid: nil)
        #expect(fixity(legacy).describesFileNow(stamp(uuid: nil)))
        #expect(fixity(legacy).describesFileNow(stamp()))              // now has a UUID: device still equal
        #expect(!fixity(legacy).describesFileNow(stamp(dev: 16_777_249)))
        #expect(!fixity(legacy).describesFileNow(stamp(dev: 16_777_249, uuid: nil)))
    }

    /// The resume/quarantine identity: legacy stamps stay device-blind (as
    /// they always were); a UUID-bearing stamp demands the same volume.
    @Test func quarantineRuleIsDeviceBlindOnlyForLegacyStamps() {
        #expect(stamp(uuid: nil).describesSameFile(now: stamp(dev: 1, uuid: uuidB), legacyVolume: .notCompared))
        #expect(stamp().describesSameFile(now: stamp(dev: 1), legacyVolume: .notCompared))
        #expect(!stamp().describesSameFile(now: stamp(uuid: uuidB), legacyVolume: .notCompared))
        #expect(!stamp().describesSameFile(now: stamp(uuid: nil), legacyVolume: .notCompared))
    }

    @Test func matchesIgnoringChangeTimeFollowsTheVolumeRule() {
        let before = stamp()
        #expect(stamp(dev: 3, ctime: 5).matchesIgnoringChangeTime(before))
        #expect(!stamp(ctime: 5, uuid: uuidB).matchesIgnoringChangeTime(before))
    }

    @Test func sameInstantHardLinkCheckStillUsesDeviceAndInode() {
        #expect(stamp().isSameFile(as: stamp(uuid: uuidB)))
        #expect(!stamp().isSameFile(as: stamp(dev: 2)))
    }
}

@Suite("ContentFixity volume identity — on-disk negatives")
struct ContentFixityVolumeIdentityDiskTests {

    @Test func captureCarriesTheRealVolumeUUID() throws {
        let dir = try scratch("capture"); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.mov"); try Data(count: 64).write(to: f)
        let s = try #require(FileIdentityStamp.capture(path: f.path))
        let viaURL = try f.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        #expect(s.volumeUUID != nil)
        #expect(s.volumeUUID == viaURL?.uppercased())
    }

    @Test func cloneRenamedOverTheOriginalIsStale() throws {
        let dir = try scratch("clone"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mov"), b = dir.appendingPathComponent("b.mov")
        try Data(repeating: 1, count: 8192).write(to: a)
        let fx = fixity(try #require(FileIdentityStamp.capture(path: a.path)))
        #expect(clonefile(a.path, b.path, 0) == 0)
        #expect(rename(b.path, a.path) == 0)
        #expect(!fx.describesFileNow(FileIdentityStamp.capture(path: a.path)), "clone = new inode")
    }

    /// Time Machine / Finder restore: a copy with the original times
    /// (copyfile COPYFILE_ALL ≈ `cp -p`) put in place by rename.
    @Test func restoreWithPreservedTimesIsStale() throws {
        let dir = try scratch("restore"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mov"), r = dir.appendingPathComponent("restored.mov")
        try Data(repeating: 2, count: 8192).write(to: a)
        let fx = fixity(try #require(FileIdentityStamp.capture(path: a.path)))
        #expect(copyfile(a.path, r.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW)) == 0)
        #expect(rename(r.path, a.path) == 0)
        #expect(!fx.describesFileNow(FileIdentityStamp.capture(path: a.path)))
    }

    @Test func atomicSaveViaRenameIsStale() throws {
        let dir = try scratch("atomic"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mov")
        try Data(repeating: 3, count: 8192).write(to: a)
        let fx = fixity(try #require(FileIdentityStamp.capture(path: a.path)))
        try Data(repeating: 3, count: 8192).write(to: a, options: .atomic)
        #expect(!fx.describesFileNow(FileIdentityStamp.capture(path: a.path)))
    }

    @Test func sameSizeRewriteWithMtimePutBackIsStale() throws {
        let dir = try scratch("rewrite"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mov")
        try Data(repeating: 4, count: 8192).write(to: a)
        let s = try #require(FileIdentityStamp.capture(path: a.path))
        let fx = fixity(s)
        let h = try FileHandle(forWritingTo: a); try h.write(contentsOf: Data(repeating: 5, count: 8192)); try h.close()
        var times = [timespec(tv_sec: Int(s.mtimeNs / 1_000_000_000), tv_nsec: Int(s.mtimeNs % 1_000_000_000)),
                     timespec(tv_sec: Int(s.mtimeNs / 1_000_000_000), tv_nsec: Int(s.mtimeNs % 1_000_000_000))]
        #expect(utimensat(AT_FDCWD, a.path, &times, 0) == 0)
        let now = try #require(FileIdentityStamp.capture(path: a.path))
        #expect(now.mtimeNs == s.mtimeNs && now.size == s.size, "precondition: user-settable fields reproduce")
        #expect(!fx.describesFileNow(now), "only the kernel ctime tells")
        #expect(fx.stampMatches(now), "the user-visible check cannot tell — by design")
    }

    /// Different disk at the same path, on disk: the seam answers another
    /// UUID for the same path — as a swapped drive would.
    @Test func swappedDiskAtTheSamePathIsStale() throws {
        let dir = try scratch("swap"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mov"); try Data(count: 64).write(to: a)
        let fx = fixity(try #require(FileIdentityStamp.capture(path: a.path)))
        let now = VolumeIdentity.$resolverOverride.withValue({ _ in uuidB }) { FileIdentityStamp.capture(path: a.path) }
        #expect(now?.volumeUUID == uuidB)
        #expect(!fx.describesFileNow(now))
    }
}

@Suite("ContentFixity volume identity — old-stamp upgrade")
struct ContentFixityVolumeIdentityUpgradeTests {

    @Test func remountedLegacyStampFromTheScannedVolumeIsUpgraded() throws {
        let legacy = fixity(stamp(uuid: nil))
        let now = stamp(dev: 16_777_249)
        guard case .upgraded(let up) = legacy.upgradedToVolumeIdentity(current: now, recordVolumeUUID: uuidA.lowercased()) else {
            Issue.record("expected an upgrade"); return
        }
        #expect(up.stamp == now && up.digest == legacy.digest && up.computedAt == legacy.computedAt)
        #expect(up.describesFileNow(now))
        #expect(up.describesFileNow(stamp(dev: 5)), "and survives the next remount")
        #expect(!legacy.describesFileNow(now), "the comparison alone never accepts it")
    }

    @Test func sameMountLegacyStampIsUpgradedWithoutAScanUUID() {
        let legacy = fixity(stamp(uuid: nil))
        #expect(legacy.upgradedToVolumeIdentity(current: stamp(), recordVolumeUUID: "") == .upgraded(fixity(stamp())
            .withComputedAt(legacy.computedAt)))
    }

    @Test func everyUnprovenCaseIsLeftStale() {
        let legacy = fixity(stamp(uuid: nil))
        let moved = stamp(dev: 16_777_249)
        #expect(legacy.upgradedToVolumeIdentity(current: moved, recordVolumeUUID: "") == .notUpgraded(.volumeNotProven))
        #expect(legacy.upgradedToVolumeIdentity(current: moved, recordVolumeUUID: uuidB) == .notUpgraded(.volumeNotProven))
        #expect(legacy.upgradedToVolumeIdentity(current: stamp(dev: 1, uuid: uuidB), recordVolumeUUID: uuidA)
                == .notUpgraded(.volumeNotProven))
        #expect(legacy.upgradedToVolumeIdentity(current: nil, recordVolumeUUID: uuidA) == .notUpgraded(.offline))
        #expect(legacy.upgradedToVolumeIdentity(current: stamp(dev: 1, uuid: nil), recordVolumeUUID: uuidA)
                == .notUpgraded(.noVolumeIdentityNow))
        #expect(legacy.upgradedToVolumeIdentity(current: stamp(uuid: nil), recordVolumeUUID: uuidA)
                == .notUpgraded(.noVolumeIdentityNow))
        for changed in [stamp(dev: 1, ino: 2), stamp(dev: 1, size: 3), stamp(dev: 1, mtime: 4), stamp(dev: 1, ctime: 5)] {
            #expect(legacy.upgradedToVolumeIdentity(current: changed, recordVolumeUUID: uuidA) == .notUpgraded(.fileChanged))
        }
        let preCtime = fixity(stamp(ctime: FileIdentityStamp.unknownCtime, uuid: nil))
        #expect(preCtime.upgradedToVolumeIdentity(current: moved, recordVolumeUUID: uuidA) == .notUpgraded(.notUsable))
        #expect(fixity(stamp()).upgradedToVolumeIdentity(current: moved, recordVolumeUUID: uuidA) == .alreadyBound)
    }

    /// Exhaustive-ish sweep: an upgrade is only ever produced when the
    /// four file fields reproduce, and its stamp IS the current stat.
    @Test func anUpgradeNeverInventsFields() {
        let legacy = fixity(stamp(uuid: nil))
        let devs: [UInt64] = [16_777_255, 1]
        let uuids: [String?] = [uuidA, uuidB, nil]
        for dev in devs {
            for u in uuids {
                for delta in 0..<5 {
                    let now = stamp(dev: dev, ino: 1_915_518 + (delta == 1 ? 1 : 0), size: 660_299_659 + (delta == 2 ? 1 : 0),
                                    mtime: 1_275_630_050_000_000_000 + (delta == 3 ? 1 : 0),
                                    ctime: 1_786_994_248_712_435_423 + (delta == 4 ? 1 : 0), uuid: u)
                    for rec in ["", uuidA, uuidB] {
                        if case .upgraded(let up) = legacy.upgradedToVolumeIdentity(current: now, recordVolumeUUID: rec) {
                            #expect(delta == 0 && u != nil && up.stamp == now)
                            #expect(dev == 16_777_255 || rec == u, "device moved: only the scanned volume's UUID proves it")
                        }
                    }
                }
            }
        }
    }
}

@Suite("ContentFixity volume identity — Codable")
struct ContentFixityVolumeIdentityCodableTests {

    @Test func oldCatalogJSONDecodesWithoutAUUIDAndReencodesTheSameKeys() throws {
        let json = #"{"device":16777255,"inode":1915518,"size":660299659,"mtimeNs":1275630050000000000,"ctimeNs":1786994248712435423}"#
        let s = try JSONDecoder().decode(FileIdentityStamp.self, from: Data(json.utf8))
        #expect(s.volumeUUID == nil && s.hasChangeTime)
        let back = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any]
        #expect(Set(back?.keys.map { $0 } ?? []) == ["device", "inode", "size", "mtimeNs", "ctimeNs"])
    }

    @Test func uuidRoundTripsAndIsNormalized() throws {
        let s = stamp(uuid: uuidA.lowercased())
        #expect(s.volumeUUID == uuidA)
        let back = try JSONDecoder().decode(FileIdentityStamp.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(stamp(uuid: "00000000-0000-0000-0000-000000000000").volumeUUID == nil)
        #expect(stamp(uuid: "").volumeUUID == nil)
    }
}

@Suite("ContentFixity volume identity — resolver seam isolation")
struct ContentFixityVolumeIdentitySeamTests {

    @Test func overrideIsScopedToTheTaskAndNeverLeaks() async throws {
        let dir = try scratch("seam"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mov"); try Data(count: 64).write(to: a)
        let real = VolumeIdentity.uuid(forPath: a.path)
        #expect(real != nil)
        async let poisoned: String? = VolumeIdentity.$resolverOverride.withValue({ _ in uuidB }) {
            try? await Task.sleep(nanoseconds: 20_000_000)
            return VolumeIdentity.uuid(forPath: a.path)
        }
        async let clean: String? = {
            try? await Task.sleep(nanoseconds: 10_000_000)
            return VolumeIdentity.uuid(forPath: a.path)
        }()
        let (p, c) = await (poisoned, clean)
        #expect(p == uuidB)
        #expect(c == real, "a sibling task never sees another task's override")
        #expect(VolumeIdentity.uuid(forPath: a.path) == real)
        let none = VolumeIdentity.$resolverOverride.withValue({ _ in nil }) { FileIdentityStamp.capture(path: a.path) }
        #expect(none != nil && none?.volumeUUID == nil)
    }
}

@Suite("ContentFixity volume identity — scale")
struct ContentFixityVolumeIdentityScaleTests {

    /// 100k stored-vs-current comparisons + 100k upgrade decisions: the
    /// comparison is pure field compares; budget is generous for Debug.
    @Test func hundredThousandComparisonsUnderBudget() {
        let n = 100_000
        let stored = (0..<n).map { i in fixity(stamp(ino: UInt64(i), uuid: i % 2 == 0 ? uuidA : nil)) }
        let current = (0..<n).map { i in stamp(dev: 9, ino: UInt64(i)) }
        let clock = ContinuousClock()
        var fresh = 0, upgraded = 0
        let elapsed = clock.measure {
            for i in 0..<n {
                if stored[i].describesFileNow(current[i]) { fresh += 1 }
                if case .upgraded = stored[i].upgradedToVolumeIdentity(current: current[i], recordVolumeUUID: uuidA) { upgraded += 1 }
            }
        }
        #expect(fresh == n / 2, "UUID stamps fresh across the remount; legacy ones not by comparison")
        #expect(upgraded == n / 2, "legacy ones upgrade via the scanned-volume UUID")
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }

    /// Real captures (stat + getattrlist + stat) — the per-file cost the
    /// consumers and the upgrade pass pay. 20k on one file < 2 s.
    @Test func captureCostUnderBudget() throws {
        let dir = try scratch("cost"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mov"); try Data(count: 64).write(to: a)
        var withUUID = 0
        let elapsed = ContinuousClock().measure {
            for _ in 0..<20_000 where FileIdentityStamp.capture(path: a.path)?.volumeUUID != nil { withUUID += 1 }
        }
        #expect(withUUID == 20_000)
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }
}

private extension ContentFixity {
    func withComputedAt(_ d: Date) -> ContentFixity {
        ContentFixity(algorithm: algorithm, digest: digest, byteCount: byteCount, stamp: stamp, computedAt: d)
    }
}
