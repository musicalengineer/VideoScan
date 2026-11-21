// TranscodeReplaceVerifiedMatrixTests.swift — the POSITIVE half of GH #500
// (Rick 2026-11-20: "transcode to a temp, verify the temp, only when
// verified could it replace anything"): the refusal added for an output
// that cannot be measured must not cost a good Replace. One row per
// container/codec of the media matrix, REAL ffmpeg and ffprobe end to end
// (no mock): a small synthetic clip is transcoded with Replace over a prior
// file at the output name, and the row shows
//   • the job finished ("Transcoded", "The previous file is in the Trash");
//   • the prior file went to the Trash seam EXACTLY once, bytes intact;
//   • the name now holds the new derivative, which real ffprobe measures
//     at the source's length (the same reading the job's verification took);
//   • the catalog has it as a derivative of the source; no partial is left.
// The negative half (scripted ffmpeg/ffprobe) is
// TranscodeReplaceNegativeMatrixTests.
//
// Parallel by design: each row has its own sandbox and binds its own Trash
// seam (TaskLocal — never the user's Trash). Memory: clips are 2 s at
// 320x240 (the largest, DV at its fixed 720x480, is ~7 MB on disk);
// SHA-256 reads the 4 KB prior blob and the small derivative whole.

import CryptoKit
import Foundation
import Testing
@testable import VideoScan

@Suite("Transcode Replace — a verified new file still replaces, across the media matrix (real ffmpeg)", .timeLimit(.minutes(3)))
@MainActor
struct TranscodeReplaceVerifiedMatrixTests {

    enum Source: String, CaseIterable, Sendable {
        case mp4H264, movProRes, mkvFFV1PCM, mxf, aviDV

        var fileName: String {
            switch self {
            case .mp4H264: "test_rvm_tape.mp4"
            case .movProRes: "test_rvm_tape.mov"
            case .mkvFFV1PCM: "test_rvm_tape.mkv"
            case .mxf: "test_rvm_tape.mxf"
            case .aviDV: "test_rvm_tape.avi"
            }
        }

        /// ffmpeg arguments between the two lavfi inputs and the output.
        var codecArgs: [String] {
            switch self {
            case .mp4H264: ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]
            case .movProRes: ["-c:v", "prores_ks", "-profile:v", "1", "-c:a", "pcm_s16le"]
            case .mkvFFV1PCM: ["-c:v", "ffv1", "-level", "3", "-c:a", "pcm_s16le"]
            case .mxf: ["-c:v", "mpeg2video", "-pix_fmt", "yuv422p", "-b:v", "8M", "-c:a", "pcm_s16le", "-ar", "48000"]
            case .aviDV: ["-c:v", "dvvideo", "-s", "720x480", "-pix_fmt", "yuv411p", "-r", "30000/1001",
                          "-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2"]
            }
        }
    }

    final class TrashLog: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    static func sha(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "missing" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static let clipSeconds = 2.0

    @Test("a real encode that verifies replaces: the prior file is trashed exactly once and the new derivative takes the name",
          arguments: Source.allCases)
    func aVerifiedReplacePublishesAndTrashesOnce(_ kind: Source) async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("rvm_\(kind.rawValue)"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)

        // The source: a real clip in this row's container and codecs.
        let srcURL = sb.sources.appendingPathComponent(kind.fileName)
        try CleanupTestMedia.runFFmpeg(
            ["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=\(Self.clipSeconds)",
             "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(Self.clipSeconds)"]
                + kind.codecArgs + ["-shortest"],
            output: srcURL.path)
        let source = MasterArchiveTestSupport.makeRecord(path: srcURL.path)
        source.durationSeconds = Self.clipSeconds

        // The prior derivative at the output name (a seeded blob).
        let outDir = sb.root.appendingPathComponent("Edits", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let target = TranscodeDestination.outputURL(in: outDir, record: source, preset: .archival)
        _ = try MasterArchiveTestSupport.writeBlob(at: target, bytes: 4096, seed: 42)
        let priorSHA = Self.sha(target)
        let prior = MasterArchiveTestSupport.makeRecord(path: target.path)
        model.records = [source, prior]

        let fakeTrash = sb.root.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        let trashed = TrashLog()

        let job = TranscodeJob(record: source, preset: .archival, outputURL: target, model: model, replaceExisting: true)
        await DerivativeOutputPublish.$trashItem.withValue({ url in
            trashed.add(url.path)
            let dest = fakeTrash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }) {
            job.start()   // the job's Task {} inherits the Trash seam
            await job.task?.value
        }

        guard case .finished(let summary) = job.state else { Issue.record("\(kind.rawValue): \(job.state)"); return }
        #expect(summary.hasPrefix("Transcoded → \(target.lastPathComponent)"), "\(summary)")
        #expect(summary.contains("The previous file is in the Trash."), "\(summary)")

        // Trashed exactly once, bytes intact; the name holds the new file.
        #expect(trashed.all == [target.path], "\(trashed.all)")
        #expect(Self.sha(fakeTrash.appendingPathComponent(target.lastPathComponent)) == priorSHA)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: fakeTrash.path))?.count == 1)
        #expect(Self.sha(target) != priorSHA, "the new derivative took the name")
        #expect(job.publishedURL == target)

        // What "verified" rests on, re-read from the published file with
        // the real tool: both lengths readable and in agreement.
        let sourceLength = await FFmpegEncodeCheck.measureDuration(srcURL.path)
        let outputLength = await FFmpegEncodeCheck.measureDuration(target.path)
        guard case .seconds(let src) = sourceLength, case .seconds(let out) = outputLength else {
            Issue.record("\(kind.rawValue): source \(sourceLength), output \(outputLength)"); return
        }
        #expect(abs(src - out) < 0.5, "source \(src) s, output \(out) s")

        // Nothing left beside it; the catalog has the derivative, once.
        let beside = ((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []).sorted()
        #expect(beside == [target.lastPathComponent], "\(beside)")
        let atName = model.records.filter { $0.fullPath == target.path }
        #expect(atName.count == 1, "\(atName.count) records at the output name")
        #expect(atName.first?.derivedFrom == source.id)
        #expect((atName.first?.durationSeconds ?? 0) > 1, "the catalog's record is of the real new file")
    }
}
