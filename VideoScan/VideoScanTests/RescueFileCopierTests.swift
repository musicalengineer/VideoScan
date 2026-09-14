// RescueFileCopierTests.swift
// Regression net for the drive-rescue copy path (fix/rescue-copy-partial-detection,
// 2026-09-13).
//
// The bug: VolumeRescueOperation.fastCopy called FileManager.copyItem
// straight to the FINAL destination name and treated any pre-existing
// destination as "already copied". An interrupted rescue therefore left a
// truncated file at a final name, and the NEXT run reported it as a good
// copy while adding the full source size to bytesWritten. On the drive
// rescue path that is silent data loss with a green checkmark over it.
//
// Five dimensions (project policy, docs/testing_retrospective_2026_07_05.md):
//   1. Logic     — fresh / resumed / short destination / leftover .partial /
//                  unreadable source, plus metadata preservation.
//   2. Sensor    — "interrupted copy never leaves a final-named file" and
//                  "a short destination is never reported as copied",
//                  pinned at both the copier and the operation level. These
//                  are the tests that must go red if anyone reverts to
//                  copyItem-at-the-final-name.
//   3. Isolation — destination directory not writable; destination
//                  directory vanishing mid-copy (the removable-volume case).
//   4. Scale     — per-file overhead over a few thousand files, with a time
//                  budget, because this path copies whole drives.
//   5. Media matrix — DELIBERATELY NOT APPLICABLE. This path copies opaque
//                  bytes; it never opens, decodes or probes media. An
//                  mp4/mov/mkv/mxf/avi matrix here would exercise nothing
//                  the byte-identity assertions don't already cover. (Said
//                  out loud rather than skipped silently.)

import Darwin
import Foundation
import Testing
@testable import VideoScan

@Suite("RescueFileCopier — .partial publish + measured bytes", .serialized)
struct RescueFileCopierTests {

    // MARK: - helpers

    private func makeSandbox(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rescuecopy_\(label)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Deterministic pseudo-random bytes (xorshift64*), so "the copy is
    /// byte-identical" is a real claim and not "both files are zeros".
    private func blob(bytes: Int, seed: UInt64) -> Data {
        var state = seed &+ 0x9E3779B97F4A7C15
        var out = [UInt8](repeating: 0, count: bytes)
        out.withUnsafeMutableBytes { raw in
            var i = 0
            while i < bytes {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                let step = min(8, bytes - i)
                withUnsafeBytes(of: state) { word in
                    raw.baseAddress!.advanced(by: i).copyMemory(from: word.baseAddress!, byteCount: step)
                }
                i += step
            }
        }
        return Data(out)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    // MARK: - 1. Logic

    @Test func freshCopyPublishesCompleteFileAndReportsMeasuredBytes() throws {
        let sb = try makeSandbox("fresh")
        defer { try? FileManager.default.removeItem(at: sb) }
        let src = sb.appendingPathComponent("src.mxf")
        let dst = sb.appendingPathComponent("dest/src.mxf")
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Deliberately spans several chunks so the write loop runs more
        // than once, plus a ragged tail.
        let payload = blob(bytes: RescueFileCopier.chunkSize * 2 + 12_345, seed: 1)
        try payload.write(to: src)

        let outcome = try RescueFileCopier.copy(source: src.path, destination: dst.path)

        #expect(outcome == .copied(bytesWritten: Int64(payload.count)))
        #expect(try Data(contentsOf: dst) == payload)
        #expect(!exists(dst.path + RescueFileCopier.partialSuffix))
    }

    @Test func emptySourceIsCopiedAsAnEmptyFile() throws {
        let sb = try makeSandbox("empty")
        defer { try? FileManager.default.removeItem(at: sb) }
        let src = sb.appendingPathComponent("empty.mov")
        let dst = sb.appendingPathComponent("empty.mov.copy")
        try Data().write(to: src)

        #expect(try RescueFileCopier.copy(source: src.path, destination: dst.path)
                == .copied(bytesWritten: 0))
        #expect(try Data(contentsOf: dst).isEmpty)
        #expect(!exists(dst.path + RescueFileCopier.partialSuffix))
    }

    @Test func resumedRescueWithSameSizedDestinationIsNotRewritten() throws {
        let sb = try makeSandbox("resumed")
        defer { try? FileManager.default.removeItem(at: sb) }
        let src = sb.appendingPathComponent("src.mov")
        let dst = sb.appendingPathComponent("dst.mov")
        let payload = blob(bytes: 64 * 1024, seed: 2)
        try payload.write(to: src)
        try payload.write(to: dst)
        let before = try FileManager.default.attributesOfItem(atPath: dst.path)[.modificationDate] as? Date

        let outcome = try RescueFileCopier.copy(source: src.path, destination: dst.path)

        #expect(outcome == .alreadyPresent(bytes: Int64(payload.count)))
        // Untouched: same mtime, same bytes. This is the legitimate skip.
        let after = try FileManager.default.attributesOfItem(atPath: dst.path)[.modificationDate] as? Date
        #expect(before == after)
        #expect(try Data(contentsOf: dst) == payload)
    }

    /// Documents the deliberate limit of Fast mode: the resumed-rescue
    /// check is SIZE only. Same size + different content is reported
    /// already-present. Fast mode advertises "no verification"; content
    /// equality is what Verified (rsync --checksum) mode is for. Pinned so
    /// nobody later reads `.alreadyPresent` as "content verified".
    @Test func sameSizeDifferentContentIsReportedAlreadyPresent_sizeOnlyByDesign() throws {
        let sb = try makeSandbox("samesize")
        defer { try? FileManager.default.removeItem(at: sb) }
        let src = sb.appendingPathComponent("src.mov")
        let dst = sb.appendingPathComponent("dst.mov")
        try blob(bytes: 4096, seed: 3).write(to: src)
        try blob(bytes: 4096, seed: 99).write(to: dst)

        #expect(try RescueFileCopier.copy(source: src.path, destination: dst.path)
                == .alreadyPresent(bytes: 4096))
    }

    /// THE BUG. A destination that is shorter than the source is an
    /// interrupted copy; it must be re-copied, never counted.
    @Test(arguments: [0, 1, 4096, RescueFileCopier.chunkSize + 7])
    func shortDestinationIsRecopiedNotCounted(shortSize: Int) throws {
        let sb = try makeSandbox("short")
        defer { try? FileManager.default.removeItem(at: sb) }
        let src = sb.appendingPathComponent("src.mxf")
        let dst = sb.appendingPathComponent("dst.mxf")
        let payload = blob(bytes: RescueFileCopier.chunkSize + 100_000, seed: 4)
        try payload.write(to: src)
        try payload.prefix(shortSize).write(to: dst)   // the truncated leftover

        let outcome = try RescueFileCopier.copy(source: src.path, destination: dst.path)

        #expect(outcome == .recopiedIncomplete(bytesWritten: Int64(payload.count),
                                               previousSize: Int64(shortSize)))
        #expect(try Data(contentsOf: dst) == payload)
        #expect(!exists(dst.path + RescueFileCopier.partialSuffix))
    }

    /// The other direction of "size doesn't match": a destination LONGER
    /// than the source is equally not this file.
    @Test func longerDestinationIsAlsoRecopied() throws {
        let sb = try makeSandbox("longer")
        defer { try? FileManager.default.removeItem(at: sb) }
        let src = sb.appendingPathComponent("src.mov")
        let dst = sb.appendingPathComponent("dst.mov")
        let payload = blob(bytes: 10_000, seed: 5)
        try payload.write(to: src)
        try blob(bytes: 20_000, seed: 6).write(to: dst)

        #expect(try RescueFileCopier.copy(source: src.path, destination: dst.path)
                == .recopiedIncomplete(bytesWritten: 10_000, previousSize: 20_000))
        #expect(try Data(contentsOf: dst) == payload)
    }

    @Test func leftoverPartialIsDiscardedAndNeverCounted() throws {
        let sb = try makeSandbox("leftover")
        defer { try? FileManager.default.removeItem(at: sb) }
        let src = sb.appendingPathComponent("src.mxf")
        let dst = sb.appendingPathComponent("dst.mxf")
        let payload = blob(bytes: 200_000, seed: 7)
        try payload.write(to: src)
        // Residue of a rescue that was interrupted mid-file.
        let partial = dst.path + RescueFileCopier.partialSuffix
        try payload.prefix(150_000).write(to: URL(fileURLWithPath: partial))

        let outcome = try RescueFileCopier.copy(source: src.path, destination: dst.path)

        // Copied from ZERO — the leftover contributed nothing.
        #expect(outcome == .copied(bytesWritten: Int64(payload.count)))
        #expect(try Data(contentsOf: dst) == payload)
        #expect(!exists(partial))
    }

    /// A stale `.partial` next to an already-complete destination is swept,
    /// not left to accumulate across repeated rescues.
    @Test func stalePartialBesideCompleteDestinationIsSwept() throws {
        let sb = try makeSandbox("sweep")
        defer { try? FileManager.default.removeItem(at: sb) }
        let src = sb.appendingPathComponent("src.mov")
        let dst = sb.appendingPathComponent("dst.mov")
        let payload = blob(bytes: 8192, seed: 8)
        try payload.write(to: src)
        try payload.write(to: dst)
        let partial = dst.path + RescueFileCopier.partialSuffix
        try Data(repeating: 0xAB, count: 99).write(to: URL(fileURLWithPath: partial))

        #expect(try RescueFileCopier.copy(source: src.path, destination: dst.path)
                == .alreadyPresent(bytes: 8192))
        #expect(!exists(partial))
    }

    @Test func unreadableSourceFailsAndPublishesNothing() throws {
        let sb = try makeSandbox("srcperm")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: sb.appendingPathComponent("src.mov").path)
            try? FileManager.default.removeItem(at: sb)
        }
        let src = sb.appendingPathComponent("src.mov")
        let dst = sb.appendingPathComponent("dst.mov")
        try blob(bytes: 1024, seed: 9).write(to: src)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: src.path)

        #expect(throws: RescueFileCopier.Failure.self) {
            try RescueFileCopier.copy(source: src.path, destination: dst.path)
        }
        #expect(!exists(dst.path))
        #expect(!exists(dst.path + RescueFileCopier.partialSuffix))
    }

    /// "Source unreadable MID-copy": the read side fails after the first
    /// chunk has already landed. Nothing may be published, and the
    /// half-written bytes must not survive under any name.
    @Test func failureMidCopyLeavesNeitherFinalFileNorPartial() throws {
        let sb = try makeSandbox("midfail")
        defer { try? FileManager.default.removeItem(at: sb) }
        let src = sb.appendingPathComponent("src.mxf")
        let dst = sb.appendingPathComponent("dst.mxf")
        try blob(bytes: RescueFileCopier.chunkSize * 3, seed: 10).write(to: src)

        let hooks = RescueFileCopier.Hooks(fsync: { Darwin.fsync($0) },
                                           afterChunk: { written in written > 0 ? EIO : 0 })
        RescueFileCopier.$hooks.withValue(hooks) {
            #expect(throws: RescueFileCopier.Failure.self) {
                try RescueFileCopier.copy(source: src.path, destination: dst.path)
            }
        }
        #expect(!exists(dst.path))
        #expect(!exists(dst.path + RescueFileCopier.partialSuffix))
    }

    @Test func sourceThatIsNotARegularFileIsRefused() throws {
        let sb = try makeSandbox("notregular")
        defer { try? FileManager.default.removeItem(at: sb) }
        let dir = sb.appendingPathComponent("a_directory")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = sb.appendingPathComponent("dst.mov")

        #expect(throws: RescueFileCopier.Failure.sourceNotRegularFile(dir.path)) {
            try RescueFileCopier.copy(source: dir.path, destination: dst.path)
        }
        #expect(!exists(dst.path))
    }

    /// A symlink squatting on the destination name is refused, never
    /// followed — otherwise a rescue could write through it to somewhere
    /// else entirely.
    @Test func symlinkAtDestinationIsRefused() throws {
        let sb = try makeSandbox("symlink")
        defer { try? FileManager.default.removeItem(at: sb) }
        let src = sb.appendingPathComponent("src.mov")
        let elsewhere = sb.appendingPathComponent("elsewhere.mov")
        let dst = sb.appendingPathComponent("dst.mov")
        try blob(bytes: 512, seed: 11).write(to: src)
        try Data(repeating: 0x11, count: 4).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(atPath: dst.path, withDestinationPath: elsewhere.path)

        #expect(throws: RescueFileCopier.Failure.self) {
            try RescueFileCopier.copy(source: src.path, destination: dst.path)
        }
        // The symlink's target was not written through.
        #expect(try Data(contentsOf: elsewhere) == Data(repeating: 0x11, count: 4))
    }

    /// Metadata parity with the `copyItem` this replaced. mtime matters
    /// because the catalog infers decade from file dates; extended
    /// attributes matter because that is where a 1990s QuickTime resource
    /// fork lives.
    @Test func modificationTimeAndExtendedAttributesSurviveTheCopy() throws {
        let sb = try makeSandbox("metadata")
        defer { try? FileManager.default.removeItem(at: sb) }
        let src = sb.appendingPathComponent("src.mov")
        let dst = sb.appendingPathComponent("dst.mov")
        try blob(bytes: 4096, seed: 12).write(to: src)

        let oldDate = Date(timeIntervalSince1970: 852_076_800)   // 1997-01-01
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: src.path)
        let xattrValue = Array("resource-fork-stand-in".utf8)
        #expect(setxattr(src.path, "com.videoscan.test", xattrValue, xattrValue.count, 0, 0) == 0)

        _ = try RescueFileCopier.copy(source: src.path, destination: dst.path)

        let copiedDate = try FileManager.default.attributesOfItem(atPath: dst.path)[.modificationDate] as? Date
        #expect(abs((copiedDate ?? .distantPast).timeIntervalSince(oldDate)) < 1.0)
        var readBack = [UInt8](repeating: 0, count: 64)
        let n = getxattr(dst.path, "com.videoscan.test", &readBack, readBack.count, 0, 0)
        #expect(n == xattrValue.count)
        #expect(Array(readBack.prefix(max(0, n))) == xattrValue)
    }

    // MARK: - 2. Sensor
    //
    // These pin the FIXED behavior at the level the bug lived at. If
    // anyone reverts to `copyItem` at the final name, or re-introduces
    // "destination exists ⇒ it's copied", these fail loudly.

    /// SENSOR: an interrupted copy never leaves a final-named file. The
    /// cancel fires after the first chunk of a multi-chunk file — exactly
    /// the moment the old code would have left a truncated .mxf sitting
    /// under the real name.
    @Test func sensor_interruptedCopyNeverLeavesAFinalNamedFile() throws {
        let sb = try makeSandbox("sensor_interrupt")
        defer { try? FileManager.default.removeItem(at: sb) }
        let src = sb.appendingPathComponent("tape.mxf")
        let dst = sb.appendingPathComponent("rescued/tape.mxf")
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try blob(bytes: RescueFileCopier.chunkSize * 4, seed: 13).write(to: src)

        var chunks = 0
        #expect(throws: RescueFileCopier.Failure.cancelled) {
            try RescueFileCopier.copy(source: src.path,
                                      destination: dst.path,
                                      shouldCancel: {
                                          defer { chunks += 1 }
                                          return chunks > 0      // stop after the first chunk
                                      })
        }
        #expect(!exists(dst.path), "a cancelled copy published a final-named file — the 2026-09-13 bug is back")
        #expect(!exists(dst.path + RescueFileCopier.partialSuffix))
        // And nothing else got left behind under the real name either.
        let listing = try FileManager.default.contentsOfDirectory(atPath: dst.deletingLastPathComponent().path)
        #expect(listing.isEmpty)
    }

    /// SENSOR: a short destination is NEVER reported as copied. Stated as
    /// its own test with an explicit failure message because this is the
    /// exact claim the old code got wrong.
    @Test func sensor_shortDestinationIsNeverReportedAsAlreadyCopied() throws {
        let sb = try makeSandbox("sensor_short")
        defer { try? FileManager.default.removeItem(at: sb) }
        let src = sb.appendingPathComponent("src.mxf")
        let dst = sb.appendingPathComponent("dst.mxf")
        let payload = blob(bytes: 500_000, seed: 14)
        try payload.write(to: src)
        try payload.prefix(120_000).write(to: dst)

        let outcome = try RescueFileCopier.copy(source: src.path, destination: dst.path)

        #expect(outcome != .alreadyPresent(bytes: 120_000),
                "a truncated rescue copy was reported as already present — silent data loss")
        #expect(try Data(contentsOf: dst) == payload)
    }

    // MARK: - 3. Isolation

    @Test func unwritableDestinationDirectoryFailsCleanly() throws {
        let sb = try makeSandbox("readonlydir")
        let destDir = sb.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destDir.path)
            try? FileManager.default.removeItem(at: sb)
        }
        let src = sb.appendingPathComponent("src.mov")
        try blob(bytes: 2048, seed: 15).write(to: src)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: destDir.path)

        let dst = destDir.appendingPathComponent("dst.mov")
        #expect(throws: RescueFileCopier.Failure.self) {
            try RescueFileCopier.copy(source: src.path, destination: dst.path)
        }
        #expect(!exists(dst.path))
    }

    /// The removable-volume case, for real rather than mocked: the
    /// destination directory is removed out from under the copy while the
    /// descriptor is open. Writes to the open fd keep succeeding (that's
    /// POSIX), and the publish step is where it must fail — with nothing
    /// under the final name.
    @Test func destinationDirectoryVanishingMidCopyPublishesNothing() throws {
        let sb = try makeSandbox("vanish")
        defer { try? FileManager.default.removeItem(at: sb) }
        let src = sb.appendingPathComponent("src.mxf")
        let destDir = sb.appendingPathComponent("Rescued")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try blob(bytes: RescueFileCopier.chunkSize * 2, seed: 16).write(to: src)
        let dst = destDir.appendingPathComponent("src.mxf")

        let dirPath = destDir.path
        let partialPath = dst.path + RescueFileCopier.partialSuffix
        let hooks = RescueFileCopier.Hooks(
            fsync: { Darwin.fsync($0) },
            afterChunk: { _ in
                // Yank the "volume": unlink the partial's name and drop the
                // directory. The write fd stays valid; the rename cannot.
                unlink(partialPath)
                rmdir(dirPath)
                return 0
            })

        RescueFileCopier.$hooks.withValue(hooks) {
            #expect(throws: RescueFileCopier.Failure.self) {
                try RescueFileCopier.copy(source: src.path, destination: dst.path)
            }
        }
        #expect(!exists(dst.path))
    }

    /// A failed durability barrier must not publish. (The archive engine
    /// has the same contract; rescue copies inherit it for the data
    /// barrier, not for the directory one — see the comment at step 9.)
    @Test func failedDataBarrierPublishesNothing() throws {
        let sb = try makeSandbox("barrier")
        defer { try? FileManager.default.removeItem(at: sb) }
        let src = sb.appendingPathComponent("src.mov")
        let dst = sb.appendingPathComponent("dst.mov")
        try blob(bytes: 4096, seed: 17).write(to: src)

        let hooks = RescueFileCopier.Hooks(fsync: { _ in -1 }, afterChunk: { _ in 0 })
        RescueFileCopier.$hooks.withValue(hooks) {
            #expect(throws: RescueFileCopier.Failure.self) {
                try RescueFileCopier.copy(source: src.path, destination: dst.path)
            }
        }
        #expect(!exists(dst.path))
        #expect(!exists(dst.path + RescueFileCopier.partialSuffix))
    }

    // MARK: - 4. Scale

    /// Whole-drive rescues are tens of thousands of files, so the per-file
    /// overhead (two opens, a create, an fsync, a rename, a directory
    /// fsync) is the thing that must stay sane — not throughput. 3,000
    /// small files with a generous budget: this is a floor-check against a
    /// future change that adds, say, a per-file hash or a directory scan.
    @Test func scale_threeThousandSmallFilesStayWithinBudget() throws {
        let sb = try makeSandbox("scale")
        defer { try? FileManager.default.removeItem(at: sb) }
        let srcDir = sb.appendingPathComponent("src")
        let dstDir = sb.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)

        let count = 3_000
        let payload = blob(bytes: 4_096, seed: 18)
        for i in 0..<count {
            try payload.write(to: srcDir.appendingPathComponent("f\(i).mov"))
        }

        let started = Date()
        var totalBytes: Int64 = 0
        for i in 0..<count {
            let outcome = try RescueFileCopier.copy(
                source: srcDir.appendingPathComponent("f\(i).mov").path,
                destination: dstDir.appendingPathComponent("f\(i).mov").path)
            if case .copied(let n) = outcome { totalBytes += n }
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(totalBytes == Int64(count * payload.count))
        // ~8 ms/file of headroom on APFS/SSD; the measured figure on the
        // M4 Max is well under 1 ms. A regression that makes this fail is
        // a per-file cost that a 50,000-file drive would turn into hours.
        #expect(elapsed < 25.0, "per-file rescue overhead regressed: \(elapsed)s for \(count) files")

        // Second pass over the same destination = the resumed-rescue path.
        // It must be cheaper still (no bytes move) and must not re-copy.
        let resumedStart = Date()
        var alreadyPresent = 0
        for i in 0..<count {
            let outcome = try RescueFileCopier.copy(
                source: srcDir.appendingPathComponent("f\(i).mov").path,
                destination: dstDir.appendingPathComponent("f\(i).mov").path)
            if case .alreadyPresent = outcome { alreadyPresent += 1 }
        }
        let resumedElapsed = Date().timeIntervalSince(resumedStart)
        #expect(alreadyPresent == count)
        #expect(resumedElapsed < 15.0, "resumed-rescue scan regressed: \(resumedElapsed)s for \(count) files")
    }
}

// MARK: - Operation-level sensor
//
// The copier is where the fix lives, but the BUG was reported at the
// operation level ("the rescue said it copied them"). These drive the real
// VolumeRescueOperation so the counters Rick reads are pinned too.

@Suite("VolumeRescueOperation — fast mode accounting", .serialized)
struct VolumeRescueOperationFastCopyTests {

    @MainActor
    private func runRescue(files: [VideoRecord], sourcePath: String, destPath: String,
                           folderName: String) async throws -> VolumeRescueOperation {
        let op = VolumeRescueOperation()
        op.start(files: files, sourcePath: sourcePath, destPath: destPath, mode: .fast, folderName: folderName)
        let deadline = Date().addingTimeInterval(60)
        while !op.isDone && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(op.isDone, "rescue did not finish within 60s")
        return op
    }

    private func record(path: String, size: Int64) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.sizeBytes = size
        r.streamTypeRaw = "Video+Audio"
        return r
    }

    /// SENSOR: a truncated file left at a final name by an earlier rescue
    /// is repaired and reported as repaired — not counted as a good copy,
    /// and its full size is not added to bytesWritten as a claim. This is
    /// the end-to-end statement of the 2026-09-13 bug.
    @MainActor
    @Test func sensor_shortDestinationIsRepairedNotCountedAsCopied() async throws {
        let sb = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rescueop_short_\(UUID().uuidString)")
        let srcVol = sb.appendingPathComponent("SourceDrive")
        let dstVol = sb.appendingPathComponent("DestDrive")
        try FileManager.default.createDirectory(at: srcVol.appendingPathComponent("Home Movies"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstVol, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sb) }

        let payload = Data(repeating: 0x5A, count: 300_000)
        let srcFile = srcVol.appendingPathComponent("Home Movies/tape1.mxf")
        try payload.write(to: srcFile)

        // Plant the residue of an interrupted rescue at the FINAL name.
        let plantedDir = dstVol.appendingPathComponent("Rescued/Home Movies")
        try FileManager.default.createDirectory(at: plantedDir, withIntermediateDirectories: true)
        let planted = plantedDir.appendingPathComponent("tape1.mxf")
        try payload.prefix(50_000).write(to: planted)

        let op = try await runRescue(files: [record(path: srcFile.path, size: Int64(payload.count))],
                                     sourcePath: srcVol.path, destPath: dstVol.path, folderName: "Rescued")

        #expect(op.filesCopied == 1)
        #expect(op.filesFailed == 0)
        #expect(op.filesRepaired == 1, "an incomplete destination was accepted as a good copy")
        #expect(op.filesAlreadyPresent == 0)
        #expect(op.bytesWritten == Int64(payload.count))
        #expect(try Data(contentsOf: planted) == payload)
    }

    /// A resumed rescue reports honest numbers: the files are safe, but
    /// this run wrote nothing. Before the fix, bytesWritten accrued the
    /// catalog's source size for every skipped file.
    @MainActor
    @Test func resumedRescueReportsZeroBytesWritten() async throws {
        let sb = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rescueop_resume_\(UUID().uuidString)")
        let srcVol = sb.appendingPathComponent("SourceDrive")
        let dstVol = sb.appendingPathComponent("DestDrive")
        try FileManager.default.createDirectory(at: srcVol, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstVol, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sb) }

        let payload = Data(repeating: 0x24, count: 120_000)
        var records: [VideoRecord] = []
        for i in 0..<3 {
            let f = srcVol.appendingPathComponent("clip\(i).mov")
            try payload.write(to: f)
            records.append(record(path: f.path, size: Int64(payload.count)))
        }

        let first = try await runRescue(files: records, sourcePath: srcVol.path,
                                        destPath: dstVol.path, folderName: "Rescued")
        #expect(first.filesCopied == 3)
        #expect(first.bytesWritten == Int64(3 * payload.count))
        #expect(first.filesAlreadyPresent == 0)

        // Same rescue again — nothing should move.
        let second = try await runRescue(files: records, sourcePath: srcVol.path,
                                         destPath: dstVol.path, folderName: "Rescued")
        #expect(second.filesCopied == 3)
        #expect(second.filesAlreadyPresent == 3)
        #expect(second.bytesWritten == 0, "a resumed rescue claimed bytes it never wrote")
        #expect(second.bytesAlreadyPresent == Int64(3 * payload.count))
        #expect(second.filesFailed == 0)
    }

    /// A missing source file is a failure, not a silent success, and it
    /// leaves nothing behind at the destination.
    @MainActor
    @Test func missingSourceIsReportedAsFailure() async throws {
        let sb = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rescueop_missing_\(UUID().uuidString)")
        let srcVol = sb.appendingPathComponent("SourceDrive")
        let dstVol = sb.appendingPathComponent("DestDrive")
        try FileManager.default.createDirectory(at: srcVol, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstVol, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sb) }

        let ghost = srcVol.appendingPathComponent("not_there.mov")
        let op = try await runRescue(files: [record(path: ghost.path, size: 1234)],
                                     sourcePath: srcVol.path, destPath: dstVol.path, folderName: "Rescued")

        #expect(op.filesCopied == 0)
        #expect(op.filesFailed == 1)
        #expect(op.bytesWritten == 0)
        #expect(op.errors.count == 1)
        #expect(!FileManager.default.fileExists(atPath: dstVol.appendingPathComponent("Rescued/not_there.mov").path))
    }

    @Test func doneSummaryReadsHonestlyForAResumedRescue() {
        let line = VolumeRescueOperation.doneSummary(safe: 40, failed: 0, bytesWritten: 0,
                                                     alreadyPresent: 40, repaired: 0)
        #expect(line.contains("40 safe"))
        #expect(line.contains("already there"))
        #expect(!line.contains("40 copied"))
    }

    @Test func doneSummaryNamesRepairedFiles() {
        let line = VolumeRescueOperation.doneSummary(safe: 10, failed: 1, bytesWritten: 2048,
                                                     alreadyPresent: 3, repaired: 2)
        #expect(line.contains("2 incomplete re-copied"))
        #expect(line.contains("1 failed"))
    }
}
