// RetireLabelNeverVouchesTests.swift
// Tab-charter audit 2026-10-11, T1: Retire accepted a "deleted" label
// (`archiveStage == .manuallyDeleted`) as proof the file was gone. 959 of
// Rick's labels were false — the file was still on the drive — so a drive
// could be retired while it held the only copy.
//
// The rule now (RetireGate.swift): a record on the drive is disposed for
// Retire only when
//   (a) it is labelled deleted AND its file is PROVABLY gone — the drive is
//       connected before and after the stats (QA m1), it is the drive the
//       catalog scanned by persistent UUID (QA M3), and ENOENT comes from a
//       folder still on the drive root's device (QA M1); or
//   (b) a witness holds now: a live row off this drive, on another
//       physical drive (device + inode rule), on disk at the same size.
// Anything else resting on a label is refused, by name, in the sheet.
// The stats run off the main actor, once per click (QA m2).
//
// Logic + scale (150k records). Disk and drive are the injected seams;
// one test drives the LIVE probe through VolumeIdentity's task-local seam.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Retire — a deleted label never vouches (audit T1)", .serialized)
@MainActor
struct RetireLabelNeverVouchesTests {

    private static let drive = "/Volumes/TestOld"
    private static let uuid = "11111111-2222-3333-4444-555555555555"

    /// The catalogued drive: its UUID is the recorded one, every folder exists on device 1.
    private static let probe = RetireDriveProbe(volumeUUID: { _ in uuid }, directoryDevice: { _ in 1 })

    private func model(_ records: [VideoRecord]) -> VideoScanModel {
        let m = VideoScanModel()
        m.records = records
        m.scanTargets = [CatalogScanTarget(searchPath: Self.drive)]
        // Separate fake drives: the device rule has its own test in
        // RetireAccountedForTests; here any other path is independent.
        m.relocateWitnessIndependence = { witness, source, _ in witness != source }
        return m
    }

    private func labelled(_ name: String, size: Int64 = 100, witness: String? = nil) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = "\(Self.drive)/\(name)"; r.filename = name; r.sizeBytes = size; r.partialMD5 = "h-\(name)"
        r.archiveStage = .manuallyDeleted
        r.scanContext.volumeUUID = Self.uuid
        if let witness {
            r.notes = VideoScanModel.formatSafelyRedundantNote(stamp: "s", source: nil,
                                                               witnesses: [witness], totalWitnessCount: 1)
        }
        return r
    }

    private func live(_ path: String, size: Int64 = 100) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path; r.filename = (path as NSString).lastPathComponent; r.sizeBytes = size; r.partialMD5 = "w"
        return r
    }

    /// A fake disk: `files` maps path → size; anything else is missing.
    private func disk(online: Bool = true, _ files: [String: Int64]) -> ShowAgainDisk {
        ShowAgainDisk(volumeOnline: { _ in online },
                      stat: { files[$0].map { .file(size: $0) } ?? .missing })
    }

    private func refusal(_ m: VideoScanModel, _ d: ShowAgainDisk,
                         drive: RetireDriveProbe = Self.probe) -> String? {
        m.retireRefusal(at: Self.drive, disk: d, drive: drive)
    }

    @Test("(a) a labelled file gone from the connected, catalogued drive is disposed")
    func labelledAndGoneRetires() {
        let m = model([labelled("gone.mov")])
        #expect(refusal(m, disk([:])) == nil)
        #expect(m.retireVolume(at: Self.drive, reason: "t", witnesses: [], disk: disk([:]), drive: Self.probe))
    }

    @Test("a labelled file still on the drive, no witness: refused, and the sheet names it")
    func labelledStillHereIsRefusedByName() throws {
        let m = model([labelled("Tapes/1994/only-copy.mov"), labelled("gone.mov")])
        let d = disk(["\(Self.drive)/Tapes/1994/only-copy.mov": 100])
        let why = try #require(refusal(m, d))
        #expect(why == "1 file(s) labelled deleted are still on this drive, with no copy on another drive: Tapes/1994/only-copy.mov")
        #expect(!m.retireVolume(at: Self.drive, reason: "t", witnesses: [], disk: d, drive: Self.probe))
        #expect(m.scanTargets.first?.isRetired == false)
    }

    @Test("(b) a labelled file still here but held by a live witness on another drive at its size retires")
    func labelledWithAHeldWitnessRetires() {
        let w = "/Volumes/Raid/clip.mov"
        let m = model([labelled("clip.mov", witness: w), live(w)])
        #expect(refusal(m, disk(["\(Self.drive)/clip.mov": 100, w: 100])) == nil)
    }

    @Test("a witness at the wrong size does not hold; the labelled file is still here → refused")
    func witnessAtTheWrongSizeDoesNotHold() {
        let w = "/Volumes/Raid/clip.mov"
        let m = model([labelled("clip.mov", witness: w), live(w)])
        #expect(refusal(m, disk(["\(Self.drive)/clip.mov": 100, w: 99]))?.contains("still on this drive") == true)
    }

    @Test("a witness on the drive's own physical device does not hold (device rule kept)")
    func sameDeviceWitnessDoesNotHold() {
        let w = "/Volumes/Raid/clip.mov"
        let m = model([labelled("clip.mov", witness: w), live(w)])
        m.relocateWitnessIndependence = { _, _, _ in false }
        #expect(refusal(m, disk(["\(Self.drive)/clip.mov": 100, w: 100])) != nil)
    }

    @Test("drive not connected: a labelled file can't be shown gone → refused, and says why")
    func offlineDriveCannotProveAbsence() throws {
        let m = model([labelled("clip.mov")])
        let why = try #require(refusal(m, disk(online: false, [:])))
        #expect(why.contains("can't be checked"), "\(why)")
        #expect(why.hasSuffix(": clip.mov"))
    }

    @Test("a stat that can't answer (permission error) is not proof the file is gone")
    func unreadableIsNotMissing() {
        let m = model([labelled("clip.mov")])
        let d = ShowAgainDisk(volumeOnline: { _ in true }, stat: { _ in .unreadable(errno: EACCES) })
        #expect(refusal(m, d)?.contains("still on this drive") == true)
    }

    @Test("more than ten files: ten names and 'and N more'")
    func longListsAreCut() throws {
        let recs = (0..<13).map { labelled("f\($0).mov") }
        let files = Dictionary(uniqueKeysWithValues: recs.map { ($0.fullPath, $0.sizeBytes) })
        let why = try #require(refusal(model(recs), disk(files)))
        #expect(why.hasPrefix("13 file(s) labelled deleted are still on this drive"))
        #expect(why.hasSuffix("f9.mov and 3 more"))
    }

    // MARK: QA round 1 — M1, M3, m1, m2

    @Test("M1: ENOENT under a folder that is gone (renamed) is not proof → unchecked")
    func missingParentFolderIsNotProof() throws {
        let m = model([labelled("Tapes/only.mov")])
        let noTapes = RetireDriveProbe(volumeUUID: { _ in Self.uuid },
                                       directoryDevice: { $0.hasSuffix("/Tapes") ? nil : 1 })
        let check = m.retireCheck(at: Self.drive, disk: disk([:]), drive: noTapes)
        #expect(check.unproven.labelledUnchecked == ["\(Self.drive)/Tapes/only.mov"])
        #expect(check.refusal?.contains("can't be checked") == true)
    }

    @Test("M1: ENOENT under a folder on ANOTHER device (a nested mount) is not proof")
    func parentOnAnotherDeviceIsNotProof() {
        let m = model([labelled("Nested/only.mov")])
        let nested = RetireDriveProbe(volumeUUID: { _ in Self.uuid },
                                      directoryDevice: { $0.hasSuffix("/Nested") ? 2 : 1 })
        #expect(m.retireCheck(at: Self.drive, disk: disk([:]), drive: nested).unproven.labelledUnchecked.count == 1)
    }

    @Test("M1: a renamed scan-target subfolder (the root itself is gone) proves nothing")
    func missingRootIsNotProof() {
        let m = model([labelled("only.mov")])
        let noRoot = RetireDriveProbe(volumeUUID: { _ in Self.uuid }, directoryDevice: { _ in nil })
        #expect(m.retireCheck(at: Self.drive, disk: disk([:]), drive: noRoot).unproven.labelledUnchecked.count == 1)
    }

    @Test("M3: a different disk mounted under the same name proves nothing")
    func anotherDiskAtTheSamePathIsNotProof() {
        let m = model([labelled("only.mov")])
        let other = RetireDriveProbe(volumeUUID: { _ in "99999999-2222-3333-4444-555555555555" },
                                     directoryDevice: { _ in 1 })
        #expect(m.retireCheck(at: Self.drive, disk: disk([:]), drive: other).unproven.labelledUnchecked.count == 1)
    }

    @Test("M3: no UUID recorded for the drive (or rows that disagree) → absence is not proof")
    func noRecordedUUIDIsNotProof() {
        let bare = labelled("only.mov"); bare.scanContext.volumeUUID = ""
        #expect(model([bare]).retireCheck(at: Self.drive, disk: disk([:]), drive: Self.probe)
            .unproven.labelledUnchecked.count == 1)
        let a = labelled("a.mov"), b = labelled("b.mov")
        b.scanContext.volumeUUID = "99999999-2222-3333-4444-555555555555"
        #expect(VideoScanModel.recordedVolumeUUID(of: [a, b]) == nil)
        #expect(model([a, b]).retireCheck(at: Self.drive, disk: disk([:]), drive: Self.probe)
            .unproven.labelledUnchecked.count == 2)
    }

    @Test("M3 through the LIVE probe: VolumeIdentity's seam answers the UUID, the real folder answers the device")
    func liveProbeUsesTheVolumeUUID() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_retire_uuid_\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tapes"), withIntermediateDirectories: true)
        let gone = VideoRecord()
        gone.fullPath = root.appendingPathComponent("Tapes/gone.mov").path; gone.filename = "gone.mov"
        gone.sizeBytes = 100; gone.archiveStage = .manuallyDeleted; gone.scanContext.volumeUUID = Self.uuid
        let m = VideoScanModel()
        m.records = [gone]
        m.scanTargets = [CatalogScanTarget(searchPath: root.path)]
        let online = ShowAgainDisk(volumeOnline: { _ in true }, stat: { ShowAgainDisk.statPath($0) })
        VolumeIdentity.$resolverOverride.withValue({ _ in Self.uuid }) {
            #expect(m.retireRefusal(at: root.path, disk: online) == nil, "the catalogued drive: absence is proof")
        }
        VolumeIdentity.$resolverOverride.withValue({ _ in "99999999-2222-3333-4444-555555555555" }) {
            #expect(m.retireRefusal(at: root.path, disk: online)?.contains("can't be checked") == true)
        }
    }

    @Test("m1: connected before the stats but not after → no absence read in the loop counts")
    func driveLeavingDuringTheLoopProvesNothing() {
        final class Asks: @unchecked Sendable { var n = 0; let lock = NSLock() }
        let asks = Asks()
        let leaving = ShowAgainDisk(volumeOnline: { _ in
            asks.lock.lock(); defer { asks.lock.unlock() }
            asks.n += 1
            return asks.n == 1
        }, stat: { _ in .missing })
        let m = model([labelled("a.mov"), labelled("b.mov")])
        let check = m.retireCheck(at: Self.drive, disk: leaving, drive: Self.probe)
        #expect(check.unproven.labelledUnchecked.count == 2)
        #expect(asks.n == 2, "asked before and after the stats")
        #expect(m.retireCheck(at: Self.drive, disk: disk([:]), drive: Self.probe).refusal == nil, "both asks true → proof")
    }

    @Test("m2: the off-main check gives the same answer, and a commit refuses if the catalog changed meanwhile")
    func offMainCheckAndStaleCommit() async {
        let m = model([labelled("gone.mov")])
        let d = disk([:])
        let check = await m.retireCheckOffMain(at: Self.drive, disk: d, drive: Self.probe)
        #expect(check == m.retireCheck(at: Self.drive, disk: d, drive: Self.probe))
        #expect(check.refusal == nil)
        m.records.append(labelled("arrived-while-checking.mov"))
        #expect(!m.commitRetire(at: Self.drive, reason: "t", witnesses: [], check: check),
                "a check of an older catalog never retires the drive")
        #expect(m.scanTargets.first?.isRetired == false)
        let fresh = await m.retireCheckOffMain(at: Self.drive, disk: d, drive: Self.probe)
        #expect(m.commitRetire(at: Self.drive, reason: "t", witnesses: [], check: fresh))
    }

    @Test("SCALE: 150k records on the drive — the gate decides within budget and names the one file still here")
    func hundredThousandRecords() throws {
        // 50k labelled + gone, 50k labelled + held by a witness on the RAID
        // (each witness a live row), one labelled file still on the drive.
        var recs: [VideoRecord] = []
        recs.reserveCapacity(150_001)
        var files: [String: Int64] = [:]
        for i in 0..<50_000 {
            recs.append(labelled("gone/\(i).mov"))
            let w = "/Volumes/Raid/\(i).mov"
            recs.append(labelled("held/\(i).mov", witness: w))
            recs.append(live(w))
            files["\(Self.drive)/held/\(i).mov"] = 100
            files[w] = 100
        }
        recs.append(labelled("still-here.mov"))
        files["\(Self.drive)/still-here.mov"] = 100
        let m = model(recs)
        let d = disk(files)
        let t0 = Date()
        let why = refusal(m, d)
        let took = -t0.timeIntervalSinceNow
        #expect(why == "1 file(s) labelled deleted are still on this drive, with no copy on another drive: still-here.mov")
        // Debug, M4 Max, 2026-10-11: the whole test (building 150k rows
        // included) took under 1 s; the budget is 3 s. O(records) + one
        // hashed lookup per witness — never O(records × witnesses).
        #expect(took < 3, "retire gate over 150k records took \(took) s")
    }
}
