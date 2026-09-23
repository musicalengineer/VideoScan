// ContentFixityVolumeIdentityTests.swift
// The 2026-09-23 volume-identity rule for FileIdentityStamp / ContentFixity
// (see the ContentFixity.swift header). Positive: a remount (new st_dev,
// same volume UUID) keeps a digest current. Negative — every one must stay
// STALE: a different disk at the same path (even with a reused st_dev),
// inode reuse, clone, restore, rename-replace, symlink retarget, same-size
// rewrite with mtime put back, UUID not resolvable now. LEGACY stamps (no
// UUID) are untrusted on any mount (codex #1707: no proof of which volume
// produced the digest). Codable compatibility, the task-local resolver
// seam (isolation), and a 100k scale budget.

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

    @Test func newStampRemountSameVolumeNewDeviceIsFresh() {
        let stored = stamp()
        let now = stamp(dev: 16_777_249)            // LaCieWorkspace after the 9/23 remount
        #expect(fixity(stored).describesFileNow(now))
        #expect(fixity(stored).describesFileNow(stamp(dev: 99)), "same disk at another mount point")
    }

    /// A different disk at the same path — even one handed the SAME st_dev
    /// (device numbers are reused across disks, measured 2026-09-23) and
    /// holding a file with the same inode, size and times — is stale.
    @Test func differentDiskIsStaleEvenWithAReusedDeviceNumber() {
        #expect(!fixity(stamp()).describesFileNow(stamp(uuid: uuidB)))
        #expect(!fixity(stamp()).describesFileNow(stamp(dev: 1, uuid: uuidB)))
    }

    @Test func uuidNotResolvableNowIsNeverAWildcard() {
        #expect(!fixity(stamp()).describesFileNow(stamp(uuid: nil)))
    }

    /// codex #1707: a legacy stamp records no volume — today's UUID plus a
    /// matching inode/size/mtime/ctime cannot prove which disk produced the
    /// digest, and no mount epoch was recorded. Untrusted on ANY mount,
    /// including one with the very same st_dev.
    @Test func legacyStampIsUntrustedOnAnyMount() {
        let legacy = fixity(stamp(uuid: nil))
        #expect(!legacy.isUsableForVerification)
        #expect(!legacy.describesFileNow(stamp(uuid: nil)), "same device, no UUID either side")
        #expect(!legacy.describesFileNow(stamp()), "same device, UUID now")
        #expect(!legacy.describesFileNow(stamp(dev: 16_777_249)), "remounted")
    }

    @Test func legacyCatalogJSONIsUntrusted() throws {
        let json = #"{"algorithm":"sha256","digest":"7a4f","byteCount":660299659,"computedAt":0,"stamp":{"device":16777255,"inode":1915518,"size":660299659,"mtimeNs":1275630050000000000,"ctimeNs":1786994248712435423}}"#
        let f = try JSONDecoder().decode(ContentFixity.self, from: Data(json.utf8))
        #expect(f.stamp.volumeUUID == nil && !f.isUsableForVerification)
        #expect(!f.describesFileNow(stamp()))
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

    @Test func preCtimeOrOtherAlgorithmNeverVerifies() {
        let old = stamp(ctime: FileIdentityStamp.unknownCtime)
        #expect(!fixity(old).describesFileNow(old) && !fixity(old).isUsableForVerification)
        let md5 = ContentFixity(algorithm: "md5", digest: "ab", byteCount: stamp().size, stamp: stamp())
        #expect(!md5.isUsableForVerification && !md5.describesFileNow(stamp()))
        let short = ContentFixity(digest: "ab", byteCount: stamp().size - 1, stamp: stamp())
        #expect(!short.describesFileNow(stamp()), "byteCount must equal the size now")
    }

    /// Same-operation identity: device AND UUID-or-none; a device number
    /// never bypasses a known UUID mismatch; one side unknown ≠ the other.
    @Test func sameOperationNeedsDeviceAndUUIDAgreement() {
        #expect(stamp().describesSameFile(now: stamp(), volume: .sameOperation))
        #expect(!stamp().describesSameFile(now: stamp(dev: 1), volume: .sameOperation))
        #expect(!stamp().describesSameFile(now: stamp(uuid: uuidB), volume: .sameOperation))
        #expect(!stamp().describesSameFile(now: stamp(uuid: nil), volume: .sameOperation))
        #expect(stamp(uuid: nil).describesSameFile(now: stamp(uuid: nil), volume: .sameOperation))
        #expect(stamp(dev: 3, ctime: 5).matchesIgnoringChangeTime(stamp(dev: 3)))
        #expect(!stamp(ctime: 5, uuid: uuidB).matchesIgnoringChangeTime(stamp()))
        #expect(fixity(stamp(uuid: nil)).stampMatches(stamp(uuid: nil)), "diagnostic check, same operation")
        #expect(!fixity(stamp()).stampMatches(stamp(dev: 1)))
    }

    /// Delete Duplicates resume: legacy plans stay device-blind (as written);
    /// a recorded UUID must reproduce.
    @Test func resumeRuleIsDeviceBlindOnlyForLegacyPlans() {
        #expect(stamp(uuid: nil).describesSameFile(now: stamp(dev: 1, uuid: uuidB), volume: .resumeAcrossRemount))
        #expect(stamp().describesSameFile(now: stamp(dev: 1), volume: .resumeAcrossRemount))
        #expect(!stamp().describesSameFile(now: stamp(uuid: uuidB), volume: .resumeAcrossRemount))
        #expect(!stamp().describesSameFile(now: stamp(uuid: nil), volume: .resumeAcrossRemount))
    }

    @Test func sameInstantHardLinkCheckUsesDeviceAndInode() {
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

    /// A symlink retargeted to a byte-identical copy with the same times:
    /// the path resolves to another inode — stale. And a retarget between
    /// open and the path check makes the capture refuse (nil).
    @Test func symlinkRetargetIsStaleAndARaceRefuses() throws {
        let dir = try scratch("symlink"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mov"), b = dir.appendingPathComponent("b.mov")
        let link = dir.appendingPathComponent("link.mov")
        try Data(repeating: 6, count: 8192).write(to: a)
        #expect(copyfile(a.path, b.path, nil, copyfile_flags_t(COPYFILE_ALL)) == 0)
        #expect(symlink(a.path, link.path) == 0)
        let fx = fixity(try #require(FileIdentityStamp.capture(path: link.path)))
        let fd = open(link.path, O_RDONLY)
        defer { close(fd) }
        #expect(unlink(link.path) == 0 && symlink(b.path, link.path) == 0)
        #expect(!fx.describesFileNow(FileIdentityStamp.capture(path: link.path)))
        #expect(FileIdentityStamp.capture(fd: fd, path: link.path) == nil, "the path no longer names the opened file")
        #expect(FileIdentityStamp.capture(fd: fd, path: nil)?.inode == fx.stamp.inode)
    }

    /// A file that can be stat'ed but not opened gets a stamp WITHOUT a
    /// UUID: fine for same-operation checks, never usable for the policy.
    @Test func unreadableFileGetsAnUnboundStamp() throws {
        let dir = try scratch("unreadable"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mov"); try Data(count: 64).write(to: a)
        #expect(chmod(a.path, 0) == 0)
        defer { chmod(a.path, 0o644) }
        let s = try #require(FileIdentityStamp.capture(path: a.path))
        #expect(s.volumeUUID == nil)
        #expect(!fixity(s).isUsableForVerification)
    }

    /// The descriptor path and the path path agree on the real UUID.
    @Test func descriptorAndPathUUIDsAgree() throws {
        let dir = try scratch("fd"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mov"); try Data(count: 64).write(to: a)
        let fd = open(a.path, O_RDONLY); defer { close(fd) }
        #expect(VolumeIdentity.uuid(forDescriptor: fd, path: nil) == VolumeIdentity.uuid(forPath: a.path))
        #expect(VolumeIdentity.uuid(forPath: a.path) != nil)
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

    /// 100k stored-vs-current comparisons: the
    /// comparison is pure field compares; budget is generous for Debug.
    @Test func hundredThousandComparisonsUnderBudget() {
        let n = 100_000
        let stored = (0..<n).map { i in fixity(stamp(ino: UInt64(i), uuid: i % 2 == 0 ? uuidA : nil)) }
        let current = (0..<n).map { i in stamp(dev: 9, ino: UInt64(i)) }
        let clock = ContinuousClock()
        var fresh = 0
        let elapsed = clock.measure {
            for i in 0..<n where stored[i].describesFileNow(current[i]) { fresh += 1 }
        }
        #expect(fresh == n / 2, "UUID stamps fresh across the remount; legacy ones never")
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }

    /// Real captures (open + fstat + fgetattrlist + stat + close) — the
    /// per-file cost every consumer pays. 20k on one file < 3 s.
    @Test func captureCostUnderBudget() throws {
        let dir = try scratch("cost"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mov"); try Data(count: 64).write(to: a)
        var withUUID = 0
        let elapsed = ContinuousClock().measure {
            for _ in 0..<20_000 where FileIdentityStamp.capture(path: a.path)?.volumeUUID != nil { withUUID += 1 }
        }
        #expect(withUUID == 20_000)
        #expect(elapsed < .seconds(3), "\(elapsed)")
    }
}
