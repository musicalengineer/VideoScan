// VolumeRescueNeverReplacesTests.swift — hard rule 2 for Volume rescue
// (Compare Volumes → copy the files this volume is missing): a rescue NEVER
// replaces, truncates or unlinks anything that is already at a destination
// name. Workflow, in Rick's words: "copy the files this volume is missing
// onto that one" — not "…and overwrite what that one has".
//
// THE BUG (found 2026-11-21, parked RED as
// `aDifferentFileAlreadyAtTheDestinationIsDestroyed`). The rescue keys a file
// by its path RELATIVE to the source volume and never asked what was already
// at that name under the destination folder:
//   • rsync mode — a successful rsync replaced whatever was there;
//   • fast mode — RescueFileCopier assumed any file of a different size at
//     the name was "an incomplete copy from an earlier run" and replaced it.
// Either way the previous bytes were UNLINKED: not in the Trash, not kept
// beside. It is reached by rescuing two volumes that hold the same relative
// path into one folder — two camera cards with DCIM/100CANON/MVI_0001.MOV.
//
// The rule, per file, decided BEFORE any transfer (refuse before mutating):
//   • nothing at the name → transfer. rsync writes only the app's staged
//     copy in `.videoscan-partial` and the app publishes it with RENAME_EXCL
//     (Codex r1 #2), as the fast copier does, so a file that appears between
//     the check and the publish is still not replaced;
//   • a regular file of the SAME size → counted "at the destination (size
//     checked)", untouched. CONTENT IS NOT COMPARED: a different file that
//     happens to be the same size is counted as already there. That is the
//     size check's stated limit (a hash of the destination is the
//     follow-up), and it is pinned below so nobody mistakes it for more;
//   • anything else (a different-size file, a directory, a symlink) → that
//     source file is FAILED "a different file is already at … — not
//     replaced", and nothing is touched. The source still has the file.
// Only this app's own partials are ever resumed or removed: rsync's
// `.videoscan-partial` folder and the copier's `<name>.partial` sidecar. A
// wrong-size file at a FINAL name is never assumed to be our own debris.
//
// Every row runs in BOTH copy modes; rsync and mkdir are the REAL tools on
// temp directories (pass-through) unless a row says otherwise. Parallel by
// design. Memory: blobs of a few KB.

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
@_spi(Testing) import VideoScanCore

@Suite("Volume rescue — never replaces, truncates or unlinks what is already at a destination name (rule 2)", .timeLimit(.minutes(1)))
@MainActor
struct VolumeRescueNeverReplacesTests {

    typealias Matrix = VolumeRescueRsyncNegativeMatrixTests
    let matrix = Matrix()

    nonisolated static func sha(_ url: URL) -> String { VolumeRescueRsyncNegativeMatrixTests.sha(url) }

    /// Real mkdir and real rsync (the fast mode issues no commands).
    func realTools(_ b: Matrix.Bench) -> ScriptedExecutor {
        b.mock().on("rsync", .passThrough)
    }

    @discardableResult
    func run(_ b: Matrix.Bench, _ mock: ScriptedExecutor, mode: RescueCopyMode) async -> Bool {
        await mock.scoped {
            b.op.start(files: b.sources.map(\.record), sourcePath: b.sourceVolume.path, destPath: b.destVolume.path, mode: mode)
            return await matrix.waitUntilDone(b)
        }
    }

    /// Put `bytes` of another file at the destination name of source 0.
    func occupy(_ b: Matrix.Bench, bytes: Int, seed: UInt64 = 404) throws -> String {
        try FileManager.default.createDirectory(at: b.dest(0).deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try MasterArchiveTestSupport.writeBlob(at: b.dest(0), bytes: bytes, seed: seed)
        return Self.sha(b.dest(0))
    }

    /// Every regular file under the destination volume.
    func files(under root: URL) -> [URL] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? [])
            .map { root.appendingPathComponent($0) }
            .filter { url in
                var isDir: ObjCBool = false
                let link = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
                return !link && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
            }
    }

    /// What every refusal shares: failed, not counted, the line names the
    /// place and says "not replaced", and the source is as it was.
    func expectRefused(_ b: Matrix.Bench, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(b.op.filesCopied == 0, "reported at the destination while a different file holds the name", sourceLocation: sourceLocation)
        #expect(b.op.filesFailed == 1 && b.op.bytesWritten == 0, "failed \(b.op.filesFailed), written \(b.op.bytesWritten)", sourceLocation: sourceLocation)
        #expect(b.op.errors.count == 1, "\(b.op.errors)", sourceLocation: sourceLocation)
        #expect(b.op.filesNameTaken == 1, "the refusal is counted as 'name taken'", sourceLocation: sourceLocation)
        #expect(b.op.filesCopied + b.op.filesFailed + b.op.filesInterrupted + b.op.filesNotAttempted == b.op.filesPlanned, sourceLocation: sourceLocation)
        // The banner's first-failure line and the summary both say it.
        #expect(VolumeRescueOperation.doneDetail(errors: b.op.errors)?.contains("a different file is already at") == true, sourceLocation: sourceLocation)
        let summary = VolumeRescueOperation.doneSummary(safe: b.op.filesCopied, failed: b.op.filesFailed, bytesWritten: b.op.bytesWritten,
                                                       alreadyPresent: b.op.filesAlreadyPresent, nameTaken: b.op.filesNameTaken)
        #expect(summary.contains("1 failed (1 not replaced: a different file was already there)"), "\(summary)", sourceLocation: sourceLocation)
        let line = b.op.errors.first ?? ""
        #expect(line.hasPrefix("\(b.sources[0].relative) — a different file is already at Rescued/\(b.sources[0].relative) ("), "\(line)", sourceLocation: sourceLocation)
        #expect(line.contains("not replaced"), "\(line)", sourceLocation: sourceLocation)
        b.expectSourcesUntouched(sourceLocation: sourceLocation)
    }

    // MARK: - A different file is at the name

    @Test("a DIFFERENT-SIZE file already at the name: the source file is FAILED 'a different file is already at …', and the file that was there survives byte for byte",
          arguments: RescueCopyMode.allCases)
    func aDifferentSizeFileIsNeverReplaced(_ mode: RescueCopyMode) async throws {
        let b = try matrix.bench(files: 1); defer { b.cleanup() }
        let earlier = try occupy(b, bytes: 30_000)
        let mock = realTools(b)
        let sink = InMemoryLogSink()
        let done = await withAppLog(sink) { await run(b, mock, mode: mode) }
        #expect(done)
        #expect(Self.sha(b.dest(0)) == earlier, "the file that was at the destination name was replaced")
        expectRefused(b)
        #expect(sink.lines.contains { $0.hasPrefix("rescue FAILED: \(b.sources[0].relative) — a different file is already at") }, "\(sink.lines)")
        #expect(sink.lines.contains { $0.hasPrefix("rescue OUTCOME: done — 1 planned: 0 at the destination (size checked) · 1 failed (1 not replaced: a different file was already there)") },
                "\(sink.lines)")
        #expect(b.op.errors.first?.contains("(30000 bytes there, \(b.sources[0].size) bytes on the source)") == true, "\(b.op.errors)")
        #expect(files(under: b.destVolume).map(\.lastPathComponent) == ["tape 1.mov"], "something was left beside it: \(files(under: b.destVolume))")
        #expect(mock.calls(to: "rsync").isEmpty, "refuse before mutating: no transfer is started for a taken name: \(mock.calls)")
    }

    /// CONTENT IS NOT COMPARED. A different file of exactly the source's
    /// size is counted as already there — untouched, which is the safe
    /// half, but "at the destination" is then a statement about a size, not
    /// about the bytes. Pinned so the limit is visible; the follow-up is a
    /// hash of the destination (or of both) before the count.
    @Test("a SAME-SIZE file with DIFFERENT content at the name: counted 'at the destination (size checked)' and left untouched — content is not compared (pinned limit)",
          arguments: RescueCopyMode.allCases)
    func aSameSizeFileIsCountedAndLeftUntouched(_ mode: RescueCopyMode) async throws {
        let b = try matrix.bench(files: 1); defer { b.cleanup() }
        let earlier = try occupy(b, bytes: Int(b.sources[0].size))
        #expect(earlier != b.sources[0].sha, "the bench: same size, different bytes")
        let mock = realTools(b)
        #expect(await run(b, mock, mode: mode))
        #expect(Self.sha(b.dest(0)) == earlier, "a same-size file at the destination was rewritten")
        #expect(b.op.filesCopied == 1 && b.op.filesFailed == 0 && b.op.errors.isEmpty, "\(b.op.errors)")
        #expect(b.op.filesAlreadyPresent == 1 && b.op.bytesWritten == 0, "it was already there: this run wrote nothing")
        #expect(mock.calls(to: "rsync").isEmpty, "\(mock.calls)")
        b.expectSourcesUntouched()
    }

    @Test("a DIRECTORY at the name: FAILED, not replaced; the directory and what is in it are still there",
          arguments: RescueCopyMode.allCases)
    func aDirectoryAtTheNameIsNeverReplaced(_ mode: RescueCopyMode) async throws {
        let b = try matrix.bench(files: 1); defer { b.cleanup() }
        try FileManager.default.createDirectory(at: b.dest(0), withIntermediateDirectories: true)
        let inside = b.dest(0).appendingPathComponent("test_inside.txt")
        try Data("kept".utf8).write(to: inside)
        let mock = realTools(b)
        #expect(await run(b, mock, mode: mode))
        expectRefused(b)
        #expect((try? Data(contentsOf: inside)) == Data("kept".utf8), "the folder at the destination name was changed")
        #expect(files(under: b.destVolume).map(\.lastPathComponent) == ["test_inside.txt"], "\(files(under: b.destVolume))")
        #expect(mock.calls(to: "rsync").isEmpty)
    }

    @Test("a SYMLINK at the name (even to a full-size copy elsewhere): FAILED, not replaced, not followed; the link and its target are untouched",
          arguments: RescueCopyMode.allCases)
    func aSymlinkAtTheNameIsNeverReplaced(_ mode: RescueCopyMode) async throws {
        let b = try matrix.bench(files: 1); defer { b.cleanup() }
        let elsewhere = b.root.appendingPathComponent("test_elsewhere.mov")
        try FileManager.default.copyItem(at: b.sources[0].url, to: elsewhere)
        let elsewhereSHA = Self.sha(elsewhere)
        try FileManager.default.createDirectory(at: b.dest(0).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: b.dest(0), withDestinationURL: elsewhere)
        let mock = realTools(b)
        #expect(await run(b, mock, mode: mode))
        expectRefused(b)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: b.dest(0).path)) == elsewhere.path, "the link was replaced")
        #expect(Self.sha(elsewhere) == elsewhereSHA, "the link was written through")
        #expect(mock.calls(to: "rsync").isEmpty)
    }

    // MARK: - A file appears between the check and the transfer

    @Test("rsync mode: a file that APPEARS at the name after the check and before the transfer is not replaced — the REAL rsync writes only the staged copy; the publish is exclusive")
    func aFileThatAppearsBeforeRsyncRunsIsNotReplaced() async throws {
        let b = try matrix.bench(files: 1); defer { b.cleanup() }
        let dest = b.dest(0)
        let appeared = TranscodeReplaceNegativeMatrixTests.Box<String>()
        // mkdir is the last thing before rsync: the name is free at the
        // check, and taken by the time rsync starts.
        let mock = ScriptedExecutor(claiming: [b.root.path])
            .on("mkdir", .custom { request in
                try? FileManager.default.createDirectory(atPath: request.arguments[1], withIntermediateDirectories: true)
                try? Data(repeating: 0x77, count: 30_000).write(to: dest)
                appeared.set(VolumeRescueNeverReplacesTests.sha(dest))
                return ProcessRunner.Result(stdout: "", stderr: "", exitCode: 0, launched: true)
            })
            .on("rsync", .passThrough)
        #expect(await run(b, mock, mode: .verified))
        #expect(mock.calls(to: "rsync").first?.arguments.last == Matrix.partial(of: dest).path, "rsync was given the final name: \(mock.calls)")
        #expect(Self.sha(dest) == appeared.value, "the file that appeared was replaced by the transfer")
        #expect(b.op.filesCopied == 0 && b.op.filesFailed == 1 && b.op.bytesWritten == 0, "\(b.op.errors)")
        #expect(b.op.errors == ["\(b.sources[0].relative) — a different file is already at Rescued/\(b.sources[0].relative) (30000 bytes there, \(b.sources[0].size) bytes on the source) "
                               + "— not replaced; nothing was touched, and the file is still on the source. The copy VideoScan staged in .videoscan-partial was removed (it was its own)."],
                "\(b.op.errors)")
        #expect(files(under: b.destVolume).map(\.lastPathComponent) == ["tape 1.mov"], "staging debris: \(files(under: b.destVolume))")
        b.expectSourcesUntouched()
    }

    /// Codex r1 #2 (P0), its reproduction with the REAL rsync:
    /// `--ignore-existing` is checked when the transfer starts, and rsync's
    /// final rename is an ordinary rename — a file that arrives at the final
    /// name DURING the transfer was overwritten. The transfer is throttled
    /// (`--bwlimit`, added in front of the production arguments), the test
    /// waits for rsync's temporary file, puts different media at the final
    /// name, and lets rsync finish: the arriving file survives byte for byte.
    @Test("rsync mode, REAL rsync: a file that ARRIVES at the final name during the transfer survives byte for byte; the source file is FAILED 'a different file is already at …'")
    func aFileArrivingDuringTheRealTransferSurvives() async throws {
        let b = try matrix.bench(files: 1); defer { b.cleanup() }
        let big = b.sources[0]
        _ = try MasterArchiveTestSupport.writeBlob(at: big.url, bytes: 768 * 1024, seed: 98)
        let bigSHA = Self.sha(big.url)
        let record = MasterArchiveTestSupport.makeRecord(path: big.url.path)
        let dest = b.dest(0), destDir = dest.deletingLastPathComponent()
        let staging = destDir.appendingPathComponent(VolumeRescueOperation.partialDirName)
        let arriving = Data(repeating: 0x77, count: 30_000)
        let slow = ScriptedExecutor(claiming: [b.root.path]).on("mkdir", .passThrough).on("rsync", .custom { request in
            var throttled = request
            throttled.arguments.insert("--bwlimit=256", at: 0)     // KB/s: ~3 s for 768 KB
            return await ScriptedExecutor().on("*", .passThrough).run(throttled)
        })
        let done = await slow.scoped {
            b.op.start(files: [record], sourcePath: b.sourceVolume.path, destPath: b.destVolume.path, mode: .verified)
            // rsync's temporary file — in the destination folder (old shape) or the staging folder.
            let deadline = ContinuousClock.now + .seconds(15)
            func underWay() -> Bool {
                [destDir, staging].contains { dir in
                    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasPrefix(".tape 1.mov.") }
                }
            }
            while ContinuousClock.now < deadline, !underWay() { try? await Task.sleep(for: .milliseconds(10)) }
            try? arriving.write(to: dest)                             // another job's file arrives at the final name
            return await matrix.waitUntilDone(b, limit: .seconds(30))
        }
        #expect(done)
        #expect((try? Data(contentsOf: dest)) == arriving, "the file that arrived during the transfer was replaced")
        #expect(b.op.filesCopied == 0 && b.op.filesFailed == 1 && b.op.bytesWritten == 0, "\(b.op.errors)")
        #expect(b.op.errors.first?.contains("a different file is already at Rescued/\(big.relative) (30000 bytes there") == true, "\(b.op.errors)")
        #expect(Self.sha(big.url) == bigSHA, "the source changed")
    }

    /// Codex r1 #7 (P1), its reproduction: the file that appears before the
    /// transfer has the SOURCE's size. Nothing of this run is at the name:
    /// it is counted as already there, with zero bytes written — not as a
    /// completed transfer of the source's size.
    @Test("rsync mode: a SAME-SIZE file that appears at the name after the check is counted 'already there' with 0 bytes written, and left untouched")
    func aSameSizeFileThatAppearsIsAlreadyThereNotWritten() async throws {
        let b = try matrix.bench(files: 1); defer { b.cleanup() }
        let dest = b.dest(0)
        let size = Int(b.sources[0].size)
        let mock = ScriptedExecutor(claiming: [b.root.path])
            .on("mkdir", .custom { request in
                try? FileManager.default.createDirectory(atPath: request.arguments[1], withIntermediateDirectories: true)
                try? Data(repeating: 0x66, count: size).write(to: dest)
                return ProcessRunner.Result(stdout: "", stderr: "", exitCode: 0, launched: true)
            })
            .on("rsync", .passThrough)
        #expect(await run(b, mock, mode: .verified))
        #expect((try? Data(contentsOf: dest)) == Data(repeating: 0x66, count: size), "the file that appeared was replaced")
        #expect(b.op.filesCopied == 1 && b.op.filesAlreadyPresent == 1 && b.op.bytesAlreadyPresent == Int64(size), "\(b.op.errors)")
        #expect(b.op.bytesWritten == 0, "a transfer that delivered nothing was reported as \(b.op.bytesWritten) bytes written")
        #expect(b.op.filesFailed == 0 && b.op.errors.isEmpty, "\(b.op.errors)")
        #expect(files(under: b.destVolume).map(\.lastPathComponent) == ["tape 1.mov"], "staging debris: \(files(under: b.destVolume))")
        b.expectSourcesUntouched()
    }

    /// Codex r1 #1 (P0), its reproduction: the destination's
    /// `.videoscan-partial` is a symlink to the SOURCE folder; after the name
    /// check sees a free name, another job puts a same-size file there; the
    /// rescue then "cleaned up its own partial" — `unlink(.videoscan-partial/
    /// <name>)` — through the link: the SOURCE file. The staging folder must
    /// be a plain folder, or the file fails with nothing touched.
    @Test("rsync mode: a `.videoscan-partial` that is a SYMLINK (here to the source folder) is never used or cleaned through — FAILED, nothing touched, the source intact")
    func aSymlinkedStagingFolderIsNeverFollowed() async throws {
        let b = try matrix.bench(files: 1); defer { b.cleanup() }
        let dest = b.dest(0)
        let staging = dest.deletingLastPathComponent().appendingPathComponent(VolumeRescueOperation.partialDirName)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: b.sources[0].url.deletingLastPathComponent())
        let size = Int(b.sources[0].size)
        let mock = ScriptedExecutor(claiming: [b.root.path])
            .on("mkdir", .custom { request in
                try? FileManager.default.createDirectory(atPath: request.arguments[1], withIntermediateDirectories: true)
                try? Data(repeating: 0x66, count: size).write(to: dest)     // another job's same-size file
                return ProcessRunner.Result(stdout: "", stderr: "", exitCode: 0, launched: true)
            })
            .on("rsync", .passThrough)
        #expect(await run(b, mock, mode: .verified))
        b.expectSourcesUntouched()
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: staging.path)) == b.sources[0].url.deletingLastPathComponent().path,
                "the link was replaced or removed")
        #expect((try? Data(contentsOf: dest)) == Data(repeating: 0x66, count: size), "the other job's file was changed")
        #expect(b.op.filesCopied == 0 && b.op.filesFailed == 1 && b.op.bytesWritten == 0, "\(b.op.errors)")
        #expect(b.op.errors.first?.contains("the staging folder at \(staging.path) is not a plain folder — nothing was touched") == true, "\(b.op.errors)")
        #expect(mock.calls(to: "rsync").isEmpty, "a transfer was started into a linked staging folder: \(mock.calls)")
    }

    /// Codex r2 #4 (P0), its reproduction: rsync completes the staged copy,
    /// then — before the publish — the user drags the rescue folder to the
    /// Trash. The held descriptors still reach the moved folders, so the
    /// publish "landed" there and the file was counted at the destination
    /// while the requested destination held nothing. Now the publish first
    /// asks whether the requested folder path still names the held folder:
    /// if not, nothing is published, the line says where the copy is, and
    /// the files after it are not attempted (a moved destination is never
    /// silently re-created by the next file's mkdir).
    @Test("rsync mode: the destination folder is MOVED (to the Trash) before the publish — nothing is published or counted; the line says where the copy now is; the rest are not attempted")
    func aDestinationMovedDuringTheRescueIsNeverPublishedInto() async throws {
        let b = try matrix.bench(files: 2); defer { b.cleanup() }
        let trash = b.root.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let rescued = b.rescued
        let mock = ScriptedExecutor(claiming: [b.root.path]).on("mkdir", .passThrough).on("rsync", .custom { request in
            let (src, staged) = (request.arguments[request.arguments.count - 2], request.arguments[request.arguments.count - 1])
            try? FileManager.default.copyItem(atPath: src, toPath: staged)                          // the staged copy is whole…
            if FileManager.default.fileExists(atPath: rescued.path) {
                try? FileManager.default.moveItem(at: rescued, to: trash.appendingPathComponent("Rescued"))   // …and the user trashes the folder
            }
            return ProcessRunner.Result(stdout: "", stderr: "", exitCode: 0, launched: true)
        })
        let sink = InMemoryLogSink()
        let done = await withAppLog(sink) { await run(b, mock, mode: .verified) }
        #expect(done)
        let realTrash = try #require(realpath(trash.path, nil).map { p in defer { free(p) }; return String(cString: p) })
        let movedCopy = "\(realTrash)/Rescued/Tapes/1994/.videoscan-partial/tape 1.mov"
        let s0 = b.sources[0], s1 = b.sources[1]
        #expect(b.op.errors == [
            "\(s0.relative) — the destination folder \(b.rescued.path)/Tapes/1994 was moved while the rescue ran — nothing was published; "
                + "the copy (size checked) is at \(movedCopy), and the file is still on the source.",
            "\(s1.relative) — not attempted: a destination folder was moved while the rescue ran (see \(s0.relative)); "
                + "nothing was copied, and the file is still on the source."], "\(b.op.errors)")
        #expect(b.op.filesCopied == 0 && b.op.filesFailed == 2 && b.op.bytesWritten == 0 && b.op.filesNameTaken == 0, "counted at a destination that holds nothing")
        #expect(b.op.filesCopied + b.op.filesFailed + b.op.filesInterrupted + b.op.filesNotAttempted == b.op.filesPlanned)
        #expect(!FileManager.default.fileExists(atPath: b.rescued.path), "the moved destination was silently re-created")
        #expect(Self.sha(URL(fileURLWithPath: movedCopy)) == s0.sha, "the staged copy in the moved folder is not kept whole")
        #expect(mock.calls(to: "rsync").count == 1 && mock.calls(to: "mkdir").count == 1, "a file was attempted after the move: \(mock.calls)")
        #expect(sink.lines.filter { $0.hasPrefix("rescue FAILED: ") }.count == 2)
        b.expectSourcesUntouched()
    }

    @Test("fast mode: a file that APPEARS at the name while the copy is being written is not replaced — the publish is an exclusive rename; the partial is removed")
    func aFileThatAppearsDuringTheFastCopyIsNotReplaced() async throws {
        let b = try matrix.bench(files: 1); defer { b.cleanup() }
        let dest = b.dest(0)
        var hooks = RescueFileCopier.Hooks.live
        hooks.afterChunk = { _ in
            if !FileManager.default.fileExists(atPath: dest.path) { try? Data(repeating: 0x77, count: 30_000).write(to: dest) }
            return 0
        }
        let done = await RescueFileCopier.$hooks.withValue(hooks) { await run(b, realTools(b), mode: .fast) }
        #expect(done)
        #expect((try? Data(contentsOf: dest)) == Data(repeating: 0x77, count: 30_000), "the file that appeared was replaced by the publish")
        #expect(b.op.filesCopied == 0 && b.op.filesFailed == 1 && b.op.bytesWritten == 0, "\(b.op.errors)")
        #expect(files(under: b.destVolume).map(\.lastPathComponent) == ["tape 1.mov"], "the copier's partial was left behind: \(files(under: b.destVolume))")
        b.expectSourcesUntouched()
    }

    // MARK: - Two camera cards, end to end

    /// The way it is reached. Card A and card B both hold
    /// DCIM/100CANON/MVI_0001.MOV — different clips. Rescue A, then rescue
    /// B into the same folder: A's clip survives byte for byte; B's clip is
    /// REPORTED, not lost — it is still on card B — and B's other clip,
    /// whose name is free, is copied.
    @Test("two camera cards with the same DCIM path, rescued into one folder: the first card's clip survives byte for byte; the second card's is reported, not lost",
          arguments: RescueCopyMode.allCases)
    func twoCameraCardsIntoOneFolder(_ mode: RescueCopyMode) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rescue-cards-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("DestVol", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        func card(_ name: String, clips: [(String, Int, UInt64)]) throws -> (volume: URL, records: [VideoRecord], shas: [String: String]) {
            let volume = root.appendingPathComponent(name, isDirectory: true)
            var records: [VideoRecord] = [], shas: [String: String] = [:]
            for (relative, bytes, seed) in clips {
                let url = volume.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try MasterArchiveTestSupport.writeBlob(at: url, bytes: bytes, seed: seed)
                records.append(MasterArchiveTestSupport.makeRecord(path: url.path))
                shas[relative] = Self.sha(url)
            }
            return (volume, records, shas)
        }
        let a = try card("CARD_A", clips: [("DCIM/100CANON/MVI_0001.MOV", 12_000, 1)])
        let b = try card("CARD_B", clips: [("DCIM/100CANON/MVI_0001.MOV", 20_000, 2), ("DCIM/100CANON/MVI_0002.MOV", 9_000, 3)])
        let landed = dest.appendingPathComponent("Rescued/DCIM/100CANON", isDirectory: true)
        let mock = ScriptedExecutor(claiming: [root.path]).on("mkdir", .passThrough).on("rsync", .passThrough)
        func rescue(_ card: (volume: URL, records: [VideoRecord], shas: [String: String])) async -> VolumeRescueOperation {
            let op = VolumeRescueOperation()
            await mock.scoped {
                op.start(files: card.records, sourcePath: card.volume.path, destPath: dest.path, mode: mode)
                let deadline = ContinuousClock.now + .seconds(20)
                while !op.isDone, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
            }
            return op
        }

        let first = await rescue(a)
        #expect(first.isDone && first.filesCopied == 1 && first.filesFailed == 0, "\(first.errors)")
        #expect(Self.sha(landed.appendingPathComponent("MVI_0001.MOV")) == a.shas["DCIM/100CANON/MVI_0001.MOV"])

        let second = await rescue(b)
        #expect(second.isDone)
        // Card A's clip is still card A's clip.
        #expect(Self.sha(landed.appendingPathComponent("MVI_0001.MOV")) == a.shas["DCIM/100CANON/MVI_0001.MOV"],
                "the second rescue destroyed the first card's clip")
        // Card B: the clash is reported; the free name is copied; nothing on the card changed.
        #expect(second.filesCopied == 1 && second.filesFailed == 1, "at destination \(second.filesCopied), failed \(second.filesFailed): \(second.errors)")
        #expect(second.errors == ["DCIM/100CANON/MVI_0001.MOV — a different file is already at Rescued/DCIM/100CANON/MVI_0001.MOV "
                                  + "(12000 bytes there, 20000 bytes on the source) — not replaced; nothing was touched, and the file is still on the source."],
                "\(second.errors)")
        #expect(Self.sha(landed.appendingPathComponent("MVI_0002.MOV")) == b.shas["DCIM/100CANON/MVI_0002.MOV"])
        for (relative, sha) in b.shas { #expect(Self.sha(b.volume.appendingPathComponent(relative)) == sha, "card B changed: \(relative)") }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: landed.path)) ?? []).sorted()
        #expect(names == ["MVI_0001.MOV", "MVI_0002.MOV"], "\(names)")
    }

    // MARK: - Our own partials are still ours

    @Test("fast mode: the copier's own leftover `<name>.partial` from an interrupted run is discarded and the file is copied whole; nothing else is touched")
    func theCopiersOwnPartialIsStillResumed() async throws {
        let b = try matrix.bench(files: 1); defer { b.cleanup() }
        try FileManager.default.createDirectory(at: b.dest(0).deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = URL(fileURLWithPath: b.dest(0).path + RescueFileCopier.partialSuffix)
        try Data(repeating: 0x11, count: 500).write(to: partial)
        #expect(await run(b, realTools(b), mode: .fast))
        #expect(b.op.filesCopied == 1 && b.op.filesFailed == 0 && b.op.errors.isEmpty, "\(b.op.errors)")
        #expect(Self.sha(b.dest(0)) == b.sources[0].sha)
        #expect(!FileManager.default.fileExists(atPath: partial.path), "the stale partial was left")
        b.expectSourcesUntouched()
    }
    // (rsync mode's own partial — `.videoscan-partial/<name>` — resumed by the
    // REAL rsync after a real interrupted transfer:
    // VolumeRescueRsyncNegativeMatrixTests.aRealInterruptedTransferNeverLeaves….)
}
