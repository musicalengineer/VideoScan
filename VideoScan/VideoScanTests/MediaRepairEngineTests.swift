import CryptoKit
import Darwin
import Foundation
import Testing
@testable import VideoScan

// MARK: - MediaRepairEngineTests (Rick 2026-10-08)
//
// "Make a fixed copy of this damaged file next to it, and show me what
// changed." The engine's safety contract, one test per outcome:
//
//   • the ORIGINAL's SHA-256 is unchanged in EVERY outcome;
//   • refusals happen before ANY write (the folder listing is unchanged);
//   • a taken target name is refused up front, and one that appears
//     mid-run is never written over and never published beside;
//   • protected folders and any FamilyArchive volume are never a target;
//   • failure keeps what ffmpeg wrote, unpublished; cancel removes it;
//   • one run, one output.
//
// Fixtures are synthetic (ffmpeg lavfi), `test_` prefixed, in a per-test
// temp dir — never real media, never a real volume. Fake "ffmpeg" scripts
// (also in the temp dir) inject failure, mismatch, a racing writer and a
// hang.

enum RepairFixtures {

    static func makeDir(_ purpose: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_media_repair_\(purpose)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func ffmpeg(_ args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ToolLocator.ffmpegPath)
        proc.arguments = ["-hide_banner", "-loglevel", "error", "-y"] + args
        proc.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        proc.standardError = err
        try proc.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "test_media_repair", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg failed: \(String(bytes: errData, encoding: .utf8) ?? "?")"
            ])
        }
    }

    /// The media matrix (CLAUDE.md feature-test checklist, dimension 3).
    enum Container: String, CaseIterable, Sendable, CustomStringConvertible {
        case mp4H264, movProRes, mkvFFV1, mxfMPEG2, aviDV
        var description: String { rawValue }

        var ext: String {
            switch self {
            case .mp4H264: return "mp4"
            case .movProRes: return "mov"
            case .mkvFFV1: return "mkv"
            case .mxfMPEG2: return "mxf"
            case .aviDV: return "avi"
            }
        }

        func encodeArgs(seconds: Int) -> [String] {
            let sine = ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds):sample_rate=48000"]
            switch self {
            case .mp4H264:
                return ["-f", "lavfi", "-i", "testsrc=duration=\(seconds):size=320x240:rate=25"] + sine
                    + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"]
            case .movProRes:
                return ["-f", "lavfi", "-i", "testsrc=duration=\(seconds):size=320x240:rate=25"] + sine
                    + ["-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s16le", "-shortest"]
            case .mkvFFV1:
                return ["-f", "lavfi", "-i", "testsrc=duration=\(seconds):size=320x240:rate=25"] + sine
                    + ["-c:v", "ffv1", "-c:a", "pcm_s16le", "-shortest"]
            case .mxfMPEG2:
                return ["-f", "lavfi", "-i", "testsrc=duration=\(seconds):size=720x576:rate=25"] + sine
                    + ["-c:v", "mpeg2video", "-pix_fmt", "yuv422p", "-b:v", "5M", "-c:a", "pcm_s16le", "-shortest"]
            case .aviDV:
                return ["-f", "lavfi", "-i", "testsrc=duration=\(seconds):size=720x576:rate=25"] + sine
                    + ["-c:v", "dvvideo", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", "-shortest"]
            }
        }
    }

    static func make(_ c: Container, in dir: URL, stem: String = "test_clip", seconds: Int = 2) throws -> URL {
        let url = dir.appendingPathComponent("\(stem).\(c.ext)")
        try ffmpeg(c.encodeArgs(seconds: seconds) + [url.path])
        return url
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func listing(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// A shell script standing in for ffmpeg. `$out` is ffmpeg's last
    /// argument — the partial the engine reserved.
    static func fakeFFmpeg(in dir: URL, body: String) throws -> String {
        let url = dir.appendingPathComponent("test_fake_ffmpeg_\(UUID().uuidString.prefix(6)).sh")
        try "#!/bin/sh\nfor a; do out=\"$a\"; done\n\(body)\n".write(to: url, atomically: false, encoding: .utf8)
        chmod(url.path, 0o755)
        return url.path
    }

    static func request(source: URL, output: URL, fixes: [MediaRepairFix] = [.remux], seconds: Double = 2,
                        protectionNote: String? = nil) -> MediaRepairRequest {
        MediaRepairRequest(sourcePath: source.path, sourceSizeBytes: size(source), sourceDurationSeconds: seconds,
                           output: output, recipe: MediaRepairRecipe(fixes: fixes, balance: nil),
                           outputProtectionNote: protectionNote, archiveCheck: nil)
    }

    static func repairedURL(for source: URL, ext: String? = nil) -> URL {
        source.deletingLastPathComponent().appendingPathComponent(
            MediaRepairOutput.fileName(sourcePath: source.path, fileExtension: ext ?? source.pathExtension))
    }

    static func run(_ req: MediaRepairRequest, tools: MediaRepairEngine.Tools = .located) async -> MediaRepairOutcome {
        await MediaRepairEngine.run(req, tools: tools, control: nil, progress: { _, _ in })
    }

    static func hasPartialOrKept(_ dir: URL) -> Bool {
        listing(dir).contains { $0.contains(".vs-partial.") || $0.contains(".vs-kept.") }
    }
}

// MARK: - Refusals (pure)

@Suite struct MediaRepairRefusalTests {

    private let src = URL(fileURLWithPath: "/tmp/test_src/test_clip.mp4")
    private let out = URL(fileURLWithPath: "/tmp/test_src/test_clip_repaired.mp4")

    private func req(fixes: [MediaRepairFix] = [.remux], output: URL? = nil, note: String? = nil) -> MediaRepairRequest {
        MediaRepairRequest(sourcePath: src.path, sourceSizeBytes: 1_000_000, sourceDurationSeconds: 10,
                           output: output ?? out, recipe: MediaRepairRecipe(fixes: fixes, balance: nil),
                           outputProtectionNote: note, archiveCheck: nil)
    }

    @Test func cleanFactsGo() {
        #expect(MediaRepairEngine.refusal(req(), facts: MediaRepairPreflightFacts()) == nil)
    }

    @Test func everyRefusalHasAReason() {
        let clean = MediaRepairPreflightFacts()
        var offline = clean; offline.sourceExists = false
        var taken = clean; taken.outputExists = true
        var noFolder = clean; noFolder.outputFolderExists = false
        var readOnly = clean; readOnly.outputFolderWritable = false
        var full = clean; full.freeBytes = 1_000
        var gate = clean; gate.outputGateNote = "lives on FamilyArchive, the Master Archive volume"
        var noTool = clean; noTool.missingTool = "ffmpeg"
        let cases: [(MediaRepairRequest, MediaRepairPreflightFacts, String)] = [
            (req(fixes: []), clean, "nothing Repair can fix"),
            (req(), offline, "isn't reachable"),
            (req(output: src), clean, "That is the original file"),
            (req(note: "lives in the Master Archive"), clean, "protected"),
            (req(), gate, "protected"),
            (req(), taken, "already there"),
            (req(), noFolder, "isn't there any more"),
            (req(), readOnly, "read-only"),
            (req(), full, "Not enough free space"),
            (req(), noTool, "ffmpeg isn't installed"),
        ]
        for (r, f, phrase) in cases {
            let why = MediaRepairEngine.refusal(r, facts: f)
            #expect(why?.contains(phrase) == true, "expected \(phrase), got \(why ?? "nil")")
        }
    }

    @Test func familyArchiveIsNeverATarget() {
        for path in ["/Volumes/FamilyArchive/1990s/test_clip_repaired.mp4",
                     "/Volumes/FamilyArchive 1/test_clip_repaired.mp4",
                     "/System/Volumes/Data/Volumes/FamilyArchive/x/test_clip_repaired.mp4"] {
            #expect(MediaRepairEngine.isFamilyArchivePath(path), "\(path)")
            let why = MediaRepairEngine.refusal(req(output: URL(fileURLWithPath: path)), facts: MediaRepairPreflightFacts())
            #expect(why?.contains("FamilyArchive") == true)
        }
        for path in ["/Volumes/LaCie/test_clip_repaired.mp4", "/Users/x/Movies/FamilyArchive/a.mp4",
                     "/Volumes/FamilyArchiveBackup/a.mp4"] {
            #expect(!MediaRepairEngine.isFamilyArchivePath(path), "\(path)")
        }
    }

    @Test func spaceNeedIncludesRebuiltPCM() {
        let copy = MediaRepairEngine.requiredFreeBytes(recipe: MediaRepairRecipe(fixes: [.remux], balance: nil),
                                                       sourceBytes: 1_000, durationSeconds: 10)
        let rebuild = MediaRepairEngine.requiredFreeBytes(recipe: MediaRepairRecipe(fixes: [.rebuildAudio], balance: nil),
                                                          sourceBytes: 1_000, durationSeconds: 10)
        #expect(copy == 1_000 + MediaRepairEngine.headroomBytes)
        #expect(rebuild == copy + 1_920_000)
    }
}

// MARK: - Outcomes on disk

@Suite(.serialized, .timeLimit(.minutes(3)))
struct MediaRepairEngineTests {

    typealias F = RepairFixtures

    @Test func losslessRemux_publishesOneOutput_originalUnchanged() async throws {
        let dir = try F.makeDir("remux")
        let src = try F.make(.mp4H264, in: dir)
        let before = try F.sha256(src)
        let out = F.repairedURL(for: src)
        let outcome = await F.run(F.request(source: src, output: out))
        guard case .repaired(let url, let proof) = outcome else {
            Issue.record("expected repaired, got \(outcome)"); return
        }
        #expect(url == out)
        #expect(proof.contains("h264"))
        #expect(try F.sha256(src) == before)
        #expect(F.listing(dir) == [src.lastPathComponent, out.lastPathComponent].sorted())
    }

    @Test func targetExists_refusedBeforeAnyWrite() async throws {
        let dir = try F.makeDir("taken")
        let src = try F.make(.mp4H264, in: dir)
        let out = F.repairedURL(for: src)
        try Data("someone else's file".utf8).write(to: out)
        let before = try F.sha256(src), theirs = try F.sha256(out), listing = F.listing(dir)
        let outcome = await F.run(F.request(source: src, output: out))
        guard case .refused(let why) = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(why.contains("already there"))
        #expect(F.listing(dir) == listing)
        #expect(try F.sha256(out) == theirs)
        #expect(try F.sha256(src) == before)
    }

    @Test func protectedFolder_refusedBeforeAnyWrite() async throws {
        let dir = try F.makeDir("protected")
        let src = try F.make(.mp4H264, in: dir)
        let before = try F.sha256(src), listing = F.listing(dir)
        let outcome = await F.run(F.request(source: src, output: F.repairedURL(for: src),
                                            protectionNote: "lives in the Master Archive, which only archive actions may change"))
        guard case .refused(let why) = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(why.contains("protected"))
        #expect(F.listing(dir) == listing)
        #expect(try F.sha256(src) == before)
    }

    @Test func offlineOriginal_refused() async throws {
        let dir = try F.makeDir("offline")
        let src = dir.appendingPathComponent("test_gone.mp4")
        let outcome = await F.run(F.request(source: src, output: F.repairedURL(for: src)))
        guard case .refused(let why) = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(why.contains("isn't reachable"))
        #expect(F.listing(dir).isEmpty)
    }

    @Test func noApplicableFix_refused() async throws {
        let dir = try F.makeDir("nofix")
        let src = try F.make(.mp4H264, in: dir)
        let listing = F.listing(dir)
        let outcome = await F.run(F.request(source: src, output: F.repairedURL(for: src), fixes: []))
        guard case .refused = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(F.listing(dir) == listing)
    }

    /// Isolation: leftovers of other runs on disk (a stale partial of the
    /// same output, a dangling symlink at the target) must not be touched
    /// or written through.
    @Test func poisonedFolder_danglingLinkAtTarget_refused_staleLeftoverUntouched() async throws {
        let dir = try F.makeDir("poisoned")
        let src = try F.make(.mp4H264, in: dir)
        let out = F.repairedURL(for: src)
        let stale = PartialFileNaming.uniquePartialURL(for: out)
        try Data("stale".utf8).write(to: stale)
        symlink(dir.appendingPathComponent("test_nowhere").path, out.path)
        let listing = F.listing(dir)
        let outcome = await F.run(F.request(source: src, output: out))
        guard case .refused(let why) = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(why.contains("already there"))
        #expect(F.listing(dir) == listing)
        #expect(try String(contentsOf: stale, encoding: .utf8) == "stale")
    }

    @Test func ffmpegFailsWritingNothing_failed_nothingKept() async throws {
        let dir = try F.makeDir("fail_empty")
        let src = try F.make(.mp4H264, in: dir)
        let before = try F.sha256(src)
        let fake = try F.fakeFFmpeg(in: dir, body: "exit 1")
        let out = F.repairedURL(for: src)
        let outcome = await F.run(F.request(source: src, output: out),
                                  tools: .init(ffmpeg: fake, ffprobe: ToolLocator.ffprobePath))
        guard case .failed(_, let kept) = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(kept == nil)
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(!F.hasPartialOrKept(dir))
        #expect(try F.sha256(src) == before)
    }

    @Test func ffmpegFailsPartway_failed_partialKeptUnpublished() async throws {
        let dir = try F.makeDir("fail_partway")
        let src = try F.make(.mp4H264, in: dir)
        let before = try F.sha256(src)
        let fake = try F.fakeFFmpeg(in: dir, body: "printf 'half a file' > \"$out\"\nexit 1")
        let out = F.repairedURL(for: src)
        let outcome = await F.run(F.request(source: src, output: out),
                                  tools: .init(ffmpeg: fake, ffprobe: ToolLocator.ffprobePath))
        guard case .failed(let why, let kept?) = outcome else { Issue.record("expected failed+kept, got \(outcome)"); return }
        #expect(why.contains("status 1"))
        #expect(kept.lastPathComponent.contains(".vs-kept."))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(try F.sha256(src) == before)
    }

    @Test func parityMismatch_failed_copyKeptUnpublished() async throws {
        let dir = try F.makeDir("parity")
        let src = try F.make(.mp4H264, in: dir)
        let other = try F.make(.mp4H264, in: dir, stem: "test_other", seconds: 3)
        let before = try F.sha256(src)
        let fake = try F.fakeFFmpeg(in: dir, body: "cp '\(other.path)' \"$out\"")
        let out = F.repairedURL(for: src)
        let outcome = await F.run(F.request(source: src, output: out),
                                  tools: .init(ffmpeg: fake, ffprobe: ToolLocator.ffprobePath))
        guard case .failed(let why, let kept?) = outcome else { Issue.record("expected failed+kept, got \(outcome)"); return }
        #expect(why.contains("didn't match"))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(try F.sha256(src) == before)
    }

    /// A file takes the target name while the copy is being written: it is
    /// never written over and the copy is NOT published beside it.
    @Test func targetAppearsMidRun_neverOverwritten_notPublishedBeside() async throws {
        let dir = try F.makeDir("race")
        let src = try F.make(.mp4H264, in: dir)
        let out = F.repairedURL(for: src)
        let before = try F.sha256(src)
        let fake = try F.fakeFFmpeg(in: dir, body: "printf intruder > '\(out.path)'\ncp '\(src.path)' \"$out\"")
        let outcome = await F.run(F.request(source: src, output: out),
                                  tools: .init(ffmpeg: fake, ffprobe: ToolLocator.ffprobePath))
        guard case .failed(let why, let kept?) = outcome else { Issue.record("expected failed+kept, got \(outcome)"); return }
        #expect(why.contains("appeared"))
        #expect(try String(contentsOf: out, encoding: .utf8) == "intruder")
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!F.listing(dir).contains { $0.hasPrefix("test_clip_repaired 2") })
        #expect(try F.sha256(src) == before)
    }

    /// A drive with neither RENAME_EXCL nor hard links: refuse to publish,
    /// keep the copy (the ExclusivePublish rule; never a plain rename).
    @Test func driveWithoutExclusivePublish_keepsCopy_unpublished() async throws {
        let dir = try F.makeDir("noexcl")
        let src = try F.make(.mp4H264, in: dir)
        let out = F.repairedURL(for: src)
        let before = try F.sha256(src)
        let outcome = await ExclusivePublish.$renameExclSyscall.withValue({ _, _ in ENOTSUP }) {
            await ExclusivePublish.$linkSyscall.withValue({ _, _ in ENOTSUP }) {
                await F.run(F.request(source: src, output: out))
            }
        }
        guard case .failed(let why, let kept?) = outcome else { Issue.record("expected failed+kept, got \(outcome)"); return }
        #expect(why.contains(ExclusivePublish.cannotPublishSafelyNote))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(try F.sha256(src) == before)
    }

    @Test func cancelled_removesPartial_publishesNothing() async throws {
        let dir = try F.makeDir("cancel")
        let src = try F.make(.mp4H264, in: dir)
        let out = F.repairedURL(for: src)
        let before = try F.sha256(src)
        let fake = try F.fakeFFmpeg(in: dir, body: "printf started > \"$out\"\nsleep 30")
        let req = F.request(source: src, output: out)
        let task = Task { await F.run(req, tools: .init(ffmpeg: fake, ffprobe: ToolLocator.ffprobePath)) }
        try await Task.sleep(nanoseconds: 700_000_000)
        task.cancel()
        let outcome = await task.value
        #expect(outcome == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(!F.hasPartialOrKept(dir))
        #expect(try F.sha256(src) == before)
    }

    @Test func rebuildSound_writesPCMCopy_sameLength() async throws {
        let dir = try F.makeDir("rebuild")
        let src = try F.make(.mp4H264, in: dir)
        let before = try F.sha256(src)
        let recipe = MediaRepairRecipe(fixes: [.rebuildAudio], balance: nil)
        let out = F.repairedURL(for: src, ext: recipe.fileExtension(sourceExtension: "mp4", audioCodec: "aac"))
        #expect(out.pathExtension == "mov")
        let outcome = await F.run(F.request(source: src, output: out, fixes: [.rebuildAudio]))
        guard case .repaired(_, let proof) = outcome else { Issue.record("expected repaired, got \(outcome)"); return }
        #expect(proof.contains("pcm_s16le"))
        #expect(try F.sha256(src) == before)
    }

    /// The CapeCod class: every real picture stored several times. The
    /// copy keeps one of each, re-timed at the real rate, same length.
    @Test func removeRepeatedFrames_retimesAtRealRate_sameLength() async throws {
        let dir = try F.makeDir("repeated")
        let src = dir.appendingPathComponent("test_repeated.mov")
        // 6 real pictures a second, each stored 5 times (30 fps on disk).
        try F.ffmpeg(["-f", "lavfi", "-i", "testsrc=duration=16:size=320x240:rate=6",
                      "-f", "lavfi", "-i", "sine=duration=16:sample_rate=48000",
                      "-vf", "fps=30", "-c:v", "mjpeg", "-q:v", "3", "-c:a", "pcm_s16le", "-shortest", src.path])
        let before = try F.sha256(src)
        let recipe = MediaRepairRecipe(fixes: [.removeRepeatedFrames], balance: nil)
        let out = F.repairedURL(for: src, ext: recipe.fileExtension(sourceExtension: "mov", audioCodec: "pcm_s16le"))
        let outcome = await F.run(F.request(source: src, output: out, fixes: [.removeRepeatedFrames], seconds: 16))
        guard case .repaired(_, let proof) = outcome else { Issue.record("expected repaired, got \(outcome)"); return }
        #expect(proof.contains("h264"))
        #expect(try F.sha256(src) == before)
        let summary = try await MediaRepairProbe.summary(path: out.path, control: nil)
        #expect(abs(summary.durationSeconds - 16) <= 1)
    }

    @Test func oneRunOneOutput_secondRunRefusedByTheFirstOutput() async throws {
        let dir = try F.makeDir("twice")
        let src = try F.make(.mp4H264, in: dir)
        let out = F.repairedURL(for: src)
        let first = await F.run(F.request(source: src, output: out))
        #expect(first.isSuccess)
        let firstSHA = try F.sha256(out)
        let second = await F.run(F.request(source: src, output: out))
        guard case .refused = second else { Issue.record("expected refused, got \(second)"); return }
        #expect(try F.sha256(out) == firstSHA)
        #expect(F.listing(dir).count == 2)
    }
}

// MARK: - Media matrix (lossless remux)

@Suite(.serialized, .timeLimit(.minutes(3)))
struct MediaRepairMediaMatrixTests {

    @Test(arguments: RepairFixtures.Container.allCases)
    func losslessRemux_provesParity_originalUnchanged(_ container: RepairFixtures.Container) async throws {
        typealias F = RepairFixtures
        let dir = try F.makeDir("matrix_\(container.rawValue)")
        let src = try F.make(container, in: dir)
        let before = try F.sha256(src)
        let out = F.repairedURL(for: src)
        let outcome = await F.run(F.request(source: src, output: out))
        guard case .repaired(let url, _) = outcome else {
            Issue.record("\(container): expected repaired, got \(outcome)"); return
        }
        #expect(url.pathExtension == container.ext)
        #expect(try F.sha256(src) == before)
        #expect(!F.hasPartialOrKept(dir))
    }
}
