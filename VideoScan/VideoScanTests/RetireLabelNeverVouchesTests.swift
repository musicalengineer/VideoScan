// RetireLabelNeverVouchesTests.swift
// Tab-charter audit 2026-10-11, T1: Retire accepted a "deleted" label
// (`archiveStage == .manuallyDeleted`) as proof the file was gone. 959 of
// Rick's labels were false — the file was still on the drive — so a drive
// could be retired while it held the only copy.
//
// The rule now: a record on the drive is disposed for Retire only when
//   (a) it is labelled deleted AND its file is not on disk on a CONNECTED
//       drive (one stat through the ShowAgainDisk seam), or
//   (b) a witness holds now: a live row off this drive, on another
//       physical drive (device + inode rule), on disk at the same size.
// A labelled file that is still there — or whose drive is not connected —
// with no witness holding is refused, by name, in the retire sheet's text.
//
// Logic + scale (150k records). The disk is the injected seam; temp dirs
// with the test_ prefix where real files are needed.

import Foundation
import Testing
@testable import VideoScan

@Suite("Retire — a deleted label never vouches (audit T1)", .serialized)
@MainActor
struct RetireLabelNeverVouchesTests {

    private static let drive = "/Volumes/TestOld"

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

    @Test("(a) a labelled file gone from a connected drive is disposed")
    func labelledAndGoneRetires() {
        let m = model([labelled("gone.mov")])
        #expect(m.retireRefusal(at: Self.drive, disk: disk([:])) == nil)
        #expect(m.retireVolume(at: Self.drive, reason: "t", witnesses: [], disk: disk([:])))
    }

    @Test("a labelled file still on the drive, no witness: refused, and the sheet names it")
    func labelledStillHereIsRefusedByName() throws {
        let m = model([labelled("Tapes/1994/only-copy.mov"), labelled("gone.mov")])
        let d = disk(["\(Self.drive)/Tapes/1994/only-copy.mov": 100])
        let why = try #require(m.retireRefusal(at: Self.drive, disk: d))
        #expect(why == "1 file(s) labelled deleted are still on this drive, with no copy on another drive: Tapes/1994/only-copy.mov")
        #expect(!m.retireVolume(at: Self.drive, reason: "t", witnesses: [], disk: d))
        #expect(m.scanTargets.first?.isRetired == false)
    }

    @Test("(b) a labelled file still here but held by a live witness on another drive at its size retires")
    func labelledWithAHeldWitnessRetires() {
        let w = "/Volumes/Raid/clip.mov"
        let m = model([labelled("clip.mov", witness: w), live(w)])
        let d = disk(["\(Self.drive)/clip.mov": 100, w: 100])
        #expect(m.retireRefusal(at: Self.drive, disk: d) == nil)
    }

    @Test("a witness at the wrong size does not hold; the labelled file is still here → refused")
    func witnessAtTheWrongSizeDoesNotHold() {
        let w = "/Volumes/Raid/clip.mov"
        let m = model([labelled("clip.mov", witness: w), live(w)])
        let d = disk(["\(Self.drive)/clip.mov": 100, w: 99])
        #expect(m.retireRefusal(at: Self.drive, disk: d)?.contains("still on this drive") == true)
    }

    @Test("a witness on the drive's own physical device does not hold (device rule kept)")
    func sameDeviceWitnessDoesNotHold() {
        let w = "/Volumes/Raid/clip.mov"
        let m = model([labelled("clip.mov", witness: w), live(w)])
        m.relocateWitnessIndependence = { _, _, _ in false }
        #expect(m.retireRefusal(at: Self.drive, disk: disk(["\(Self.drive)/clip.mov": 100, w: 100])) != nil)
    }

    @Test("drive not connected: a labelled file can't be shown gone → refused, and says why")
    func offlineDriveCannotProveAbsence() throws {
        let m = model([labelled("clip.mov")])
        let why = try #require(m.retireRefusal(at: Self.drive, disk: disk(online: false, [:])))
        #expect(why.contains("can't be checked"), "\(why)")
        #expect(why.hasSuffix(": clip.mov"))
    }

    @Test("a stat that can't answer (permission error) is not proof the file is gone")
    func unreadableIsNotMissing() {
        let m = model([labelled("clip.mov")])
        let d = ShowAgainDisk(volumeOnline: { _ in true }, stat: { _ in .unreadable(errno: EACCES) })
        #expect(m.retireRefusal(at: Self.drive, disk: d)?.contains("still on this drive") == true)
    }

    @Test("more than ten files: ten names and 'and N more'")
    func longListsAreCut() throws {
        let recs = (0..<13).map { labelled("f\($0).mov") }
        let files = Dictionary(uniqueKeysWithValues: recs.map { ($0.fullPath, $0.sizeBytes) })
        let why = try #require(model(recs).retireRefusal(at: Self.drive, disk: disk(files)))
        #expect(why.hasPrefix("13 file(s) labelled deleted are still on this drive"))
        #expect(why.hasSuffix("f9.mov and 3 more"))
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
        let why = m.retireRefusal(at: Self.drive, disk: d)
        let took = -t0.timeIntervalSinceNow
        #expect(why == "1 file(s) labelled deleted are still on this drive, with no copy on another drive: still-here.mov")
        // Debug, M4 Max, 2026-10-11: the whole test (building 150k rows
        // included) took 0.86 s; the budget is 3 s. O(records) + one hashed
        // lookup per witness — never O(records × witnesses).
        #expect(took < 3, "retire gate over 150k records took \(took) s")
    }
}
