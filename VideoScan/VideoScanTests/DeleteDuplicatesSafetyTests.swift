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
private func dupRecord(path: String, size: Int64, md5: String,
                       group: UUID, disposition: DuplicateDisposition) -> VideoRecord {
    let r = VideoRecord()
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
    @Test func partialMD5CollisionSurvivesDeletion() throws {
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

        let result = model.deleteDuplicates(onVolume: dir.path)

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
    @Test func trulyIdenticalCopyIsStillDeleted() throws {
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

        let result = model.deleteDuplicates(onVolume: dir.path)

        #expect(result.deleted == 1)
        #expect(!FileManager.default.fileExists(atPath: copyURL.path))
        #expect(FileManager.default.fileExists(atPath: keeperURL.path),
                "the KEEPER must never be the file that gets removed")
    }

    /// A same-size, same-hash file whose content differs everywhere is
    /// the easy case — but it must also be refused, not merely the
    /// subtle middle-byte case.
    @Test func whollyDifferentContentIsRefused() throws {
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

        #expect(model.deleteDuplicates(onVolume: dir.path).deleted == 0)
        #expect(FileManager.default.fileExists(atPath: copyURL.path))
    }

    /// An unreadable or vanished keeper means we cannot verify, and
    /// "cannot verify" must never fall through to "delete anyway".
    @Test func unverifiableKeeperRefusesDeletion() throws {
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

        #expect(model.deleteDuplicates(onVolume: dir.path).deleted == 0)
        #expect(FileManager.default.fileExists(atPath: copyURL.path),
                "an unverifiable pair must leave the file on disk")
    }
}
