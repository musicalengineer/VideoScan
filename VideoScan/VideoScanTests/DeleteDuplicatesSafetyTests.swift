import Foundation
import Testing
@testable import VideoScan

// MARK: - Delete Duplicates safety (codex #333)
//
// This suite exists because of a real, shipped defect, and it tests the
// ACTUAL deletion API rather than the verification helper — a gate that
// exists but is never called protects nothing, which is exactly what
// went wrong.
//
// THE DEFECT. `deleteDuplicates(onVolume:)` calls
// `FileManager.removeItem` — permanent, not the Trash — on every record
// the scorer marked `.extraCopy`. The scorer's strongest signal is
// `partialMD5` + size: a 64 KB HEAD-AND-TAIL hash that never reads the
// middle of a file. Two Avid MXF essence files from one session share a
// wrapper header and can be padded to the same length; add a matching
// filename stem (3 points) and duration (3) to the hash's 8 and they
// reach 14, past the high-confidence threshold of 12.
//
// Two distinct family videos, permanently deleted, silently. The exact
// failure the segmented hash was introduced to prevent — while the
// deletion path went on trusting the weaker hash.
//
// I had also told codex "nothing destructive exists in the app". That
// was false. These tests are the standing proof it stays fixed.

@MainActor
private func makeModel(_ dir: URL) -> VideoScanModel {
    let model = VideoScanModel()
    model.catalogStore = CatalogStore(directory: dir)
    return model
}

private func write(_ url: URL, _ bytes: [UInt8]) {
    FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
}

/// A record shaped like something the scorer would call a high-confidence
/// extra copy.
@MainActor
private func dupRecord(id: UUID = UUID(), path: String, size: Int64, md5: String,
                       group: UUID, disposition: DuplicateDisposition) -> VideoRecord {
    let r = VideoRecord(id: id)
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.sizeBytes = size
    r.partialMD5 = md5
    r.durationSeconds = 61.0
    r.duplicateGroupID = group
    r.duplicateDisposition = disposition
    r.duplicateConfidence = .high
    return r
}

@Suite(.serialized)
@MainActor
struct DeleteDuplicatesSafetyTests {

    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DelDup-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// THE regression. Two files that a partialMD5 comparison cannot
    /// tell apart — identical first and last 64 KB, identical size —
    /// but whose middles differ. The scorer calls them duplicates. The
    /// deletion API must NOT remove either one.
    @Test func partialMD5CollisionSurvivesDeletion() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 256 KB: head and tail chunks are 64 KB each, so bytes
        // 65536..<196608 are invisible to partialMD5.
        let size = 256 * 1024
        var keeperBytes = [UInt8](repeating: 0xAB, count: size)
        var copyBytes = keeperBytes
        copyBytes[130_000] = 0x01      // squarely in the unread middle

        let keeperURL = dir.appendingPathComponent("Session01.mxf")
        let copyURL = dir.appendingPathComponent("Session01 copy.mxf")
        write(keeperURL, keeperBytes)
        write(copyURL, copyBytes)

        // Precondition: the OLD gate really cannot tell them apart.
        #expect(FileHasher.partialMD5(path: keeperURL.path)
                == FileHasher.partialMD5(path: copyURL.path),
                "precondition: partialMD5 is blind here — that is the defect")

        let model = makeModel(dir)
        let group = UUID()
        let keeper = dupRecord(path: keeperURL.path, size: Int64(size),
                               md5: "same", group: group, disposition: .keep)
        let copy = dupRecord(path: copyURL.path, size: Int64(size),
                             md5: "same", group: group, disposition: .extraCopy)
        model.records = [keeper, copy]

        let result = await model.deleteDuplicates(onVolume: dir.path)

        #expect(result.deleted == 0, "a non-identical file was DELETED")
        #expect(FileManager.default.fileExists(atPath: copyURL.path),
                "the copy must survive — its bytes differ from the keeper")
        #expect(FileManager.default.fileExists(atPath: keeperURL.path))
        #expect(copy.duplicateDisposition == .review,
                "a refused pair must be re-marked, not silently left as extraCopy")
        keeperBytes.removeAll(); copyBytes.removeAll()
    }

    /// Genuinely identical files still delete — verification must not
    /// break the feature it protects.
    @Test func trulyIdenticalCopyIsStillDeleted() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bytes = (0..<200_000).map { UInt8($0 % 251) }
        let keeperURL = dir.appendingPathComponent("Xmas1994.mov")
        let copyURL = dir.appendingPathComponent("Xmas1994 copy.mov")
        write(keeperURL, bytes)
        write(copyURL, bytes)

        let model = makeModel(dir)
        let group = UUID()
        model.records = [
            dupRecord(path: keeperURL.path, size: 200_000, md5: "m",
                      group: group, disposition: .keep),
            dupRecord(path: copyURL.path, size: 200_000, md5: "m",
                      group: group, disposition: .extraCopy),
        ]

        let result = await model.deleteDuplicates(onVolume: dir.path)

        #expect(result.deleted == 1)
        #expect(!FileManager.default.fileExists(atPath: copyURL.path))
        #expect(FileManager.default.fileExists(atPath: keeperURL.path),
                "the KEEPER must never be the file that gets removed")
    }

    /// A same-size, same-hash file whose content differs everywhere is
    /// the easy case — but it must also be refused, not merely the
    /// subtle middle-byte case.
    @Test func whollyDifferentContentIsRefused() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let keeperURL = dir.appendingPathComponent("a.mov")
        let copyURL = dir.appendingPathComponent("b.mov")
        write(keeperURL, [UInt8](repeating: 1, count: 5_000))
        write(copyURL, [UInt8](repeating: 2, count: 5_000))

        let model = makeModel(dir)
        let group = UUID()
        model.records = [
            dupRecord(path: keeperURL.path, size: 5_000, md5: "x",
                      group: group, disposition: .keep),
            dupRecord(path: copyURL.path, size: 5_000, md5: "x",
                      group: group, disposition: .extraCopy),
        ]

        let result = await model.deleteDuplicates(onVolume: dir.path)
        #expect(result.deleted == 0)
        #expect(FileManager.default.fileExists(atPath: copyURL.path))
    }

    /// An unreadable or vanished keeper means we cannot verify, and
    /// "cannot verify" must never fall through to "delete anyway".
    @Test func unverifiableKeeperRefusesDeletion() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let copyURL = dir.appendingPathComponent("orphan.mov")
        write(copyURL, [UInt8](repeating: 9, count: 1_000))

        let model = makeModel(dir)
        let group = UUID()
        model.records = [
            dupRecord(path: dir.appendingPathComponent("gone.mov").path,
                      size: 1_000, md5: "y", group: group, disposition: .keep),
            dupRecord(path: copyURL.path, size: 1_000, md5: "y",
                      group: group, disposition: .extraCopy),
        ]

        let result = await model.deleteDuplicates(onVolume: dir.path)
        #expect(result.deleted == 0)
        #expect(FileManager.default.fileExists(atPath: copyURL.path),
                "an unverifiable pair must leave the file on disk")
    }

    /// A target that was already absent was not deleted by this operation,
    /// so it must not be silently removed from the catalog as a success.
    @Test func alreadyMissingTargetIsNotCountedOrRemoved() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let keeperURL = dir.appendingPathComponent("keeper.mov")
        write(keeperURL, [UInt8](repeating: 7, count: 1_000))
        let missingURL = dir.appendingPathComponent("already-gone.mov")
        let group = UUID()
        let keeper = dupRecord(path: keeperURL.path, size: 1_000, md5: "z",
                               group: group, disposition: .keep)
        let missing = dupRecord(path: missingURL.path, size: 1_000, md5: "z",
                                group: group, disposition: .extraCopy)
        let model = makeModel(dir)
        model.records = [keeper, missing]

        let result = await model.deleteDuplicates(onVolume: dir.path)

        #expect(result.deleted == 0)
        #expect(model.records.contains { $0.id == missing.id },
                "catalog removal must be driven by successful deletion IDs")
        #expect(missing.duplicateDisposition == .review)
    }

    /// Isolation/read-only sensor: a viewer shares the real catalog but must
    /// never mutate archive media, even if a stale confirmation sheet or a
    /// direct caller reaches the model API after the UI changed modes.
    @Test func readOnlyViewerCannotDeleteDuplicate() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keeperURL = dir.appendingPathComponent("keeper.mov")
        let copyURL = dir.appendingPathComponent("copy.mov")
        write(keeperURL, [1, 2, 3, 4])
        write(copyURL, [1, 2, 3, 4])
        let group = UUID()
        let model = makeModel(dir)
        model.records = [
            dupRecord(path: keeperURL.path, size: 4, md5: "same",
                      group: group, disposition: .keep),
            dupRecord(path: copyURL.path, size: 4, md5: "same",
                      group: group, disposition: .extraCopy),
        ]
        model.applyReadOnlyMode(true)

        let result = await model.deleteDuplicates(onVolume: dir.path)

        #expect(result.deleted == 0)
        #expect(FileManager.default.fileExists(atPath: copyURL.path))
        #expect(model.records.count == 2)
        #expect(model.duplicateStatus.contains("viewer mode"))
    }

    /// Reentry sensor: the model guard is authoritative because a second
    /// Task can outlive or bypass SwiftUI's disabled menu state.
    @Test func activeDeletionRefusesReentry() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keeperURL = dir.appendingPathComponent("keeper.mov")
        let copyURL = dir.appendingPathComponent("copy.mov")
        write(keeperURL, [5, 6, 7, 8])
        write(copyURL, [5, 6, 7, 8])
        let group = UUID()
        let model = makeModel(dir)
        model.records = [
            dupRecord(path: keeperURL.path, size: 4, md5: "same",
                      group: group, disposition: .keep),
            dupRecord(path: copyURL.path, size: 4, md5: "same",
                      group: group, disposition: .extraCopy),
        ]
        model.isDeletingDuplicates = true

        let result = await model.deleteDuplicates(onVolume: dir.path)

        #expect(result.deleted == 0)
        #expect(model.isDeletingDuplicates)
        #expect(FileManager.default.fileExists(atPath: copyURL.path))
        #expect(model.records.count == 2)
    }

    /// The disk worker awaits off-main. If live reload replaces a row while
    /// that await is suspended, success for the old snapshot must not remove
    /// the replacement row merely because its UUID still matches.
    @Test func catalogReplacementDuringAwaitIsRetained() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keeperURL = dir.appendingPathComponent("keeper.mov")
        let copyURL = dir.appendingPathComponent("copy.mov")
        write(keeperURL, [UInt8](repeating: 4, count: FileHasher.segmentSize * 2))
        write(copyURL, [UInt8](repeating: 4, count: FileHasher.segmentSize * 2))
        let group = UUID()
        let targetID = UUID()
        let model = makeModel(dir)
        model.records = [
            dupRecord(path: keeperURL.path, size: 2_097_152, md5: "same",
                      group: group, disposition: .keep),
            dupRecord(id: targetID, path: copyURL.path, size: 2_097_152, md5: "same",
                      group: group, disposition: .extraCopy),
        ]
        let allowHashing = DispatchSemaphore(value: 0)
        let gate = NSLock()
        var paused = false
        var hashingStarted = false
        let hooks = SignatureVerification.Hooks(
            shouldCancel: { Task.isCancelled },
            didReadBlock: { _ in
                let shouldPause = gate.withLock {
                    let firstBlock = !paused
                    paused = true
                    hashingStarted = true
                    return firstBlock
                }
                if shouldPause {
                    allowHashing.wait()
                }
            })

        let deletion = Task {
            await model.deleteDuplicates(onVolume: dir.path,
                                         verificationHooks: hooks)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let started = gate.withLock { hashingStarted }
            if started { break }
            await Task.yield()
        }
        let didStart = gate.withLock { hashingStarted }
        #expect(didStart)
        let replacementPath = dir.appendingPathComponent("replacement.mov").path
        model.records = [VideoRecord(id: targetID)]
        model.records[0].fullPath = replacementPath
        model.records[0].filename = "replacement.mov"
        allowHashing.signal()
        let result = await deletion.value

        #expect(result.deleted == 1)
        #expect(model.records.count == 1)
        #expect(model.records[0].id == targetID)
        #expect(model.records[0].fullPath == replacementPath)
    }

    /// Cancelling the main-actor operation must cancel its unstructured disk
    /// worker too; otherwise the detached hash could continue into deletion.
    @Test func cancellationPropagatesIntoHashWorker() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keeperURL = dir.appendingPathComponent("keeper.mov")
        let copyURL = dir.appendingPathComponent("copy.mov")
        let bytes = [UInt8](repeating: 8, count: FileHasher.segmentSize * 2)
        write(keeperURL, bytes)
        write(copyURL, bytes)
        let group = UUID()
        let model = makeModel(dir)
        model.records = [
            dupRecord(path: keeperURL.path, size: Int64(bytes.count), md5: "same",
                      group: group, disposition: .keep),
            dupRecord(path: copyURL.path, size: Int64(bytes.count), md5: "same",
                      group: group, disposition: .extraCopy),
        ]
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var started = false
        var paused = false
        let hooks = SignatureVerification.Hooks(
            shouldCancel: { Task.isCancelled },
            didReadBlock: { _ in
                let shouldPause = lock.withLock {
                    let first = !paused
                    paused = true
                    started = true
                    return first
                }
                if shouldPause { release.wait() }
            })
        let deletion = Task {
            await model.deleteDuplicates(onVolume: dir.path,
                                         verificationHooks: hooks)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline,
              !lock.withLock({ started }) {
            await Task.yield()
        }
        #expect(lock.withLock { started })
        deletion.cancel()
        release.signal()
        let result = await deletion.value

        #expect(result.deleted == 0)
        #expect(FileManager.default.fileExists(atPath: copyURL.path))
        #expect(model.records.count == 2)
    }

    @Test("100k deletion planning stays linear and under budget",
          .timeLimit(.minutes(1)))
    func planningScale100k() {
        let model = makeModel(URL(fileURLWithPath: "/tmp"))
        let volume = "/Volumes/ScaleDelete"
        let group = UUID()
        var catalog: [VideoRecord] = []
        catalog.reserveCapacity(100_000)
        catalog.append(dupRecord(
            path: "\(volume)/keeper.mov", size: 1, md5: "same",
            group: group, disposition: .keep))
        for index in 1..<100_000 {
            catalog.append(dupRecord(
                path: "\(volume)/copy-\(index).mov", size: 1, md5: "same",
                group: group, disposition: .extraCopy))
        }
        model.records = catalog

        let start = ContinuousClock.now
        let selection = model.duplicateDeletionSelection(onVolume: volume)
        let elapsed = start.duration(to: .now)

        #expect(selection.targets.count == 99_999)
        #expect(selection.skippedCount == 0)
        #expect(elapsed < .seconds(2),
                "100k duplicate planning exceeded 2 seconds: \(elapsed)")
    }

    @Test("full verification deletes identical files across the media matrix",
          .timeLimit(.minutes(3)),
          arguments: duplicateDeletionMediaCases)
    func mediaMatrix(testCase: DuplicateDeletionMediaCase) async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable,
                     "ffmpeg is a required project dependency")
        let dir = try VerifyAudioTestMedia.makeScratchDir("duplicate-matrix")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try VerifyAudioTestMedia.generate(
            into: dir,
            name: testCase.filename,
            videoCodec: testCase.videoCodec,
            extraVideoArgs: testCase.extraVideoArgs,
            audioCodec: testCase.audioCodec,
            size: testCase.size,
            rate: testCase.rate)
        let sourceURL = URL(fileURLWithPath: source)
        let copyURL = dir.appendingPathComponent(
            "test_copy_" + sourceURL.lastPathComponent)
        try FileManager.default.copyItem(at: sourceURL, to: copyURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: source)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let group = UUID()
        let model = makeModel(dir)
        model.records = [
            dupRecord(path: source, size: size, md5: "matrix",
                      group: group, disposition: .keep),
            dupRecord(path: copyURL.path, size: size, md5: "matrix",
                      group: group, disposition: .extraCopy),
        ]

        let result = await model.deleteDuplicates(onVolume: dir.path)

        #expect(result.deleted == 1, "\(testCase.label): identical copy survived")
        #expect(FileManager.default.fileExists(atPath: source))
        #expect(!FileManager.default.fileExists(atPath: copyURL.path))
    }
}

struct DuplicateDeletionMediaCase: Sendable, CustomStringConvertible {
    let label: String
    let filename: String
    let videoCodec: String
    let extraVideoArgs: [String]
    let audioCodec: String
    let size: String
    let rate: String

    var description: String { label }
}

private let duplicateDeletionMediaCases = [
    DuplicateDeletionMediaCase(
        label: "mp4/h264+aac", filename: "test_dup_matrix.mp4",
        videoCodec: "libx264", extraVideoArgs: ["-preset", "ultrafast"],
        audioCodec: "aac", size: "320x240", rate: "25"),
    DuplicateDeletionMediaCase(
        label: "mov/prores+pcm", filename: "test_dup_matrix.mov",
        videoCodec: "prores", extraVideoArgs: [],
        audioCodec: "pcm_s16le", size: "320x240", rate: "25"),
    DuplicateDeletionMediaCase(
        label: "mkv/ffv1+pcm", filename: "test_dup_matrix.mkv",
        videoCodec: "ffv1", extraVideoArgs: [],
        audioCodec: "pcm_s16le", size: "320x240", rate: "25"),
    DuplicateDeletionMediaCase(
        label: "mxf/mpeg2+pcm", filename: "test_dup_matrix.mxf",
        videoCodec: "mpeg2video", extraVideoArgs: ["-g", "15"],
        audioCodec: "pcm_s16le", size: "720x576", rate: "25"),
    DuplicateDeletionMediaCase(
        label: "avi/dv+pcm", filename: "test_dup_matrix.avi",
        videoCodec: "dvvideo", extraVideoArgs: ["-pix_fmt", "yuv411p"],
        audioCodec: "pcm_s16le", size: "720x480", rate: "30000/1001"),
]
