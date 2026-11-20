// FrameIndexMediaMatrixTests.swift — Index Frames against REAL decoding
// (Observations/FrameSearch/: FrameIndexEngine.productionExtract, the job,
// FrameThumbnails), the media-matrix dimension of rule 8.
//
// Each clip is made by ffmpeg: 2 s of solid red, then 2 s of solid blue.
// A stand-in model answers with one axis for a red frame and another for a
// blue one, so a test can say WHICH picture was decoded at WHICH time
// without the 1.5 GB SigLIP weights.
//
//   MATRIX     mp4/h264, mov/prores, mkv/ffv1+pcm, mxf/mpeg2, avi/dv through
//              the engine's production decode door: every asked time decodes,
//              and the frame at each time is the picture that is there (red
//              before 2 s, blue after) — AVFoundation and the ffmpeg fallback.
//   TRUTH      the five files through the JOB into an index on disk, then the
//              window's store over that index: "red" finds only frames from
//              the first half of each clip, "blue" only from the second.
//   ISOLATION  bytes that are not a video, a clip cut short, a sound-only
//              file: the FILE's fault, in the decoder's words; a file deleted
//              before the decode: left for the next run, nothing recorded.
//   THUMBNAIL  the grid's thumbnail is the frame at that time, at most 320 px,
//              kept in the bounded cache; a file that is not there has none.
// Generated media only (colour cards and a tone); every folder is a temp folder.

import CoreGraphics
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// A stand-in model that only tells red from blue: red → axis 0, blue → axis 1, anything else → axis 7.
private struct ColourEmbedder: FrameEmbedding {
    let modelID = "test/stub-siglip"
    let dims = 8
    func embed(images: [CGImage]) async throws -> [[Float]] { images.map { ObsStubEmbedder.axis(Self.colour($0)) } }
    func embed(text: String) async throws -> [Float] { try await ObsStubEmbedder().embed(text: text) }

    static func colour(_ image: CGImage) -> Int {
        guard let px = SigLIPPixels.normalizedHWC(image, size: 8) else { return 7 }
        var r: Float = 0, b: Float = 0
        for i in stride(from: 0, to: px.count, by: 3) { r += px[i]; b += px[i + 2] }
        if r > 0, b < 0 { return 0 }
        if b > 0, r < 0 { return 1 }
        return 7
    }
}

enum FrameMatrixClips {
    static let ffmpeg = FileManager.default.isExecutableFile(atPath: ToolLocator.ffmpegPath)

    enum Container: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case mp4H264 = "mp4/h264", movProRes = "mov/prores", mkvFFV1 = "mkv/ffv1+pcm", mxfMPEG2 = "mxf/mpeg2", aviDV = "avi/dv"
        var testDescription: String { rawValue }

        var ext: String {
            switch self {
            case .mp4H264: return "mp4"
            case .movProRes: return "mov"
            case .mkvFFV1: return "mkv"
            case .mxfMPEG2: return "mxf"
            case .aviDV: return "avi"
            }
        }

        /// Codec arguments (the picture is 720 × 576 at 25 fps for all five — the one size DV accepts).
        var codec: [String] {
            switch self {
            case .mp4H264: return ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "12"]
            case .movProRes: return ["-c:v", "prores_ks", "-profile:v", "0"]
            case .mkvFFV1: return ["-c:v", "ffv1", "-c:a", "pcm_s16le"]
            case .mxfMPEG2: return ["-c:v", "mpeg2video", "-pix_fmt", "yuv420p", "-b:v", "4M"]
            case .aviDV: return ["-c:v", "dvvideo", "-pix_fmt", "yuv420p"]
            }
        }

        /// The matrix names one container with sound (mkv/ffv1+pcm); the others are picture only.
        var hasSound: Bool { self == .mkvFFV1 }
    }

    static let seconds = 4.0

    /// 2 s red then 2 s blue (with a 440 Hz tone where the container is the one with sound).
    static func make(_ container: Container, in dir: URL, name: String? = nil) async throws -> String {
        let path = dir.appendingPathComponent((name ?? "clip-\(container.ext)") + "." + container.ext).path
        var arguments = ["-v", "error", "-y",
                         "-f", "lavfi", "-i", "color=c=red:s=720x576:r=25:d=2",
                         "-f", "lavfi", "-i", "color=c=blue:s=720x576:r=25:d=2"]
        if container.hasSound { arguments += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=4"] }
        arguments += ["-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]", "-map", "[v]"]
        if container.hasSound { arguments += ["-map", "2:a"] }
        let made = await ProcessRunner.runProcess(executable: ToolLocator.ffmpegPath, arguments: arguments + container.codec + [path], deadlineSeconds: 120)
        try #require(made.exitCode == 0, "ffmpeg made \(container.rawValue): \(made.stderr)")
        return path
    }

    static let whereabouts = FrameIndexEngine.whereabouts(volumeOnline: { VolumeReachability.isVolumeReachable(path: $0) },
                                                          fileExists: { FileManager.default.fileExists(atPath: $0) })
    static let red = ObsStubEmbedder.axis(0), blue = ObsStubEmbedder.axis(1)
}

@Suite("Frames mode — real decode (media matrix)", .timeLimit(.minutes(5)), .enabled(if: FrameMatrixClips.ffmpeg, "ffmpeg is not installed"))
struct FrameIndexMediaMatrixTests {

    // MARK: Matrix

    @Test(arguments: FrameMatrixClips.Container.allCases)
    func everyAskedTimeDecodesToThePictureThatIsThere(_ container: FrameMatrixClips.Container) async throws {
        let dir = try ObsFixture.tempDir("frame-matrix")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try await FrameMatrixClips.make(container, in: dir)
        let outcome = await FrameIndexEngine.outcome(path: path, durationSeconds: FrameMatrixClips.seconds, framesPerFile: 4,
                                                     extract: FrameIndexEngine.productionExtract, embedder: ColourEmbedder(), whereabouts: FrameMatrixClips.whereabouts)
        guard case .indexed(let frames) = outcome else { Issue.record("\(container.rawValue) must decode: \(outcome)"); return }
        let asked = FrameIndexEngine.timestamps(durationSeconds: FrameMatrixClips.seconds, framesPerFile: 4)   // 0.2, 1.4, 2.6, 3.8
        #expect(frames.map(\.seconds) == asked, "\(container.rawValue): every asked time decoded, in order")
        #expect(frames.map(\.vector) == [FrameMatrixClips.red, FrameMatrixClips.red, FrameMatrixClips.blue, FrameMatrixClips.blue],
                "\(container.rawValue): the frame at each time is the picture at that time (red before 2 s, blue after)")
    }

    // MARK: Isolation (the real decoder's verdicts)

    @Test func aFileThatIsNotAVideoIsTheFilesFaultAndADeletedOneIsNot() async throws {
        let dir = try ObsFixture.tempDir("frame-matrix")
        defer { try? FileManager.default.removeItem(at: dir) }
        func outcome(_ path: String) async -> FrameIndexFileOutcome {
            await FrameIndexEngine.outcome(path: path, durationSeconds: FrameMatrixClips.seconds, framesPerFile: 2,
                                           extract: FrameIndexEngine.productionExtract, embedder: ColourEmbedder(), whereabouts: FrameMatrixClips.whereabouts)
        }
        // Noise with a video's name.
        let noise = dir.appendingPathComponent("noise.mp4").path
        try Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) }).write(to: URL(fileURLWithPath: noise))
        guard case .unreadable(let why) = await outcome(noise) else { Issue.record("noise must be unreadable"); return }
        #expect(!why.isEmpty, "the decoder's words are what is recorded")

        // A real mp4 that lost its tail (its index sits at the end, so nothing can be decoded).
        let whole = try await FrameMatrixClips.make(.mp4H264, in: dir, name: "whole")
        let cut = dir.appendingPathComponent("cut.mp4").path
        let bytes = try Data(contentsOf: URL(fileURLWithPath: whole))
        try bytes.prefix(bytes.count * 6 / 10).write(to: URL(fileURLWithPath: cut))
        guard case .unreadable = await outcome(cut) else { Issue.record("a clip with no index must be unreadable"); return }

        // Sound only.
        let tone = dir.appendingPathComponent("tone.wav").path
        let made = await ProcessRunner.runProcess(executable: ToolLocator.ffmpegPath,
                                                  arguments: ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=2", tone], deadlineSeconds: 60)
        try #require(made.exitCode == 0, "\(made.stderr)")
        guard case .unreadable = await outcome(tone) else { Issue.record("a file with no picture has no frame to index"); return }

        // Deleted between the plan and the decode: not the file's fault — nothing may be recorded against it.
        try FileManager.default.removeItem(atPath: whole)
        guard case .deferred(.notAtPath) = await outcome(whole) else { Issue.record("a file that is gone is left for the next run"); return }
    }

    // MARK: Truth, end to end: files → job → index on disk → the window's search

    @Test @MainActor func theFiveContainersThroughTheJobAreFoundByColourAtTheRightTimes() async throws {
        let dir = try ObsFixture.tempDir("frame-matrix")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("index", isDirectory: true)
        var rows: [CatalogRow.FrameIndexFile] = []
        for (n, container) in FrameMatrixClips.Container.allCases.enumerated() {
            rows.append(ObsFixture.row(n + 1, path: try await FrameMatrixClips.make(container, in: dir), duration: FrameMatrixClips.seconds))
        }
        let noise = dir.appendingPathComponent("noise.mp4").path
        try Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) }).write(to: URL(fileURLWithPath: noise))
        rows.append(ObsFixture.row(6, path: noise, duration: FrameMatrixClips.seconds))
        let fixed = rows

        let job = FrameIndexJob(scope: .folder(dir.path), loadFiles: { _ in fixed }, embedder: ColourEmbedder())   // the production decode and whereabouts
        job.root = root
        job.framesPerFile = 4
        job.note = { _ in }
        job.start()
        await job.task?.value
        #expect(job.outcome == .finished && job.indexed == 5 && job.unreadable == 1 && job.framesAdded == 20, "\(job.state)")
        let index = try #require(ObsFixture.onDisk(root).index)
        #expect(index.count == 20 && index.indexedDigests == Set((1...5).map(ObsFixture.digest)))
        #expect(index.failures.keys.sorted() == [ObsFixture.digest(6)], "only the noise is recorded as unreadable")

        let store = FrameSearchStore(scope: .folder(dir.path), loader: ObsFixture.frameLoader(index: { ObsFixture.onDisk(root) }, files: { _ in fixed }))
        await store.loadIndex()
        #expect(store.indexState == .ready(frames: 20, contents: 5))
        await store.search("axis 0")   // "red"
        #expect(store.hits.count == 10 && store.hits.allSatisfy { $0.score > 0.99 && $0.seconds < 2 }, "red is only in the first half of each clip: \(store.hits.map(\.seconds))")
        #expect(Set(store.hits.map(\.filename)) == Set(fixed.prefix(5).map(\.filename)), "every container is found")
        await store.search("axis 1")   // "blue"
        #expect(store.hits.count == 10 && store.hits.allSatisfy { $0.score > 0.99 && $0.seconds > 2 }, "blue is only in the second half: \(store.hits.map(\.seconds))")

        // A second run has nothing to do: the five are indexed and the noise is recorded, not ground on again.
        let again = FrameIndexJob(scope: .folder(dir.path), loadFiles: { _ in fixed }, embedder: ColourEmbedder())
        again.root = root
        again.note = { _ in }
        again.start()
        await again.task?.value
        #expect(again.planned == 0 && again.alreadyDone == 6 && again.outcome == .finished)
    }

    // MARK: Thumbnails

    @Test func aThumbnailIsTheFrameAtThatTimeAtMostThreeHundredTwentyAcrossAndIsKept() async throws {
        let dir = try ObsFixture.tempDir("frame-matrix")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try await FrameMatrixClips.make(.mp4H264, in: dir)
        let thumbnails = FrameThumbnails()
        let early = try #require(await thumbnails.image(path: path, seconds: 1), "a frame at 1 s")
        let late = try #require(await thumbnails.image(path: path, seconds: 3), "a frame at 3 s")
        #expect(early.width == 320 && (255...256).contains(early.height), "720 × 576 shrunk to the grid's edge: \(early.width) × \(early.height)")
        #expect(ColourEmbedder.colour(early) == 0 && ColourEmbedder.colour(late) == 1, "truth: the thumbnail is the picture at its own time (red at 1 s, blue at 3 s)")
        #expect(await thumbnails.image(path: dir.appendingPathComponent("never-was.mp4").path, seconds: 1) == nil, "no file, no thumbnail")

        // Asked again, it comes from the bounded cache — even with the drive gone the tile keeps its picture.
        try FileManager.default.removeItem(atPath: path)
        let kept = await thumbnails.image(path: path, seconds: 1)
        #expect(kept === early, "the same image, not a second decode")
        #expect(await thumbnails.image(path: path, seconds: 2.5) == nil, "a time never decoded has nothing to show once the file is gone")
    }
}
