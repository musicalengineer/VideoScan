// SubprocessEnvironmentTests.swift — the one builder of a child process's
// environment (SubprocessEnvironment.swift), moved from the app 2026-11-04.
//   LOGIC      augmentedPath: Homebrew first, inherited kept, POSIX default
//              for nil/empty, never a trailing ":"; mediaTools: the folders
//              of the ffmpeg/ffprobe FFmpegLocator resolves come first, each
//              folder once, every other key kept; an executable
//              VS_FFMPEG_PATH override wins.
//   ISOLATION  no tool anywhere → a Refusal naming the tool, the override
//              and every candidate path (never a PATH that cannot work).

import Foundation
import Testing
@testable import VideoScanCore

/// A FileManager that finds no executable anywhere (a Mac with no ffmpeg).
final class NoExecutablesFileManager: FileManager, @unchecked Sendable {
    override func isExecutableFile(atPath path: String) -> Bool { false }
}

@Suite("SubprocessEnvironment — the one PATH rule for child processes")
struct SubprocessEnvironmentTests {

    @Test func augmentedPathPutsHomebrewFirstAndNeverEndsInAColon() {
        #expect(SubprocessEnvironment.augmentedPath(inheriting: "/usr/bin:/bin") == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        #expect(SubprocessEnvironment.augmentedPath(inheriting: nil) == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(SubprocessEnvironment.augmentedPath(inheriting: "") == SubprocessEnvironment.augmentedPath(inheriting: nil))
    }

    @Test func mediaToolsPutsTheResolvedToolsFoldersFirstOnceEachAndKeepsEveryOtherKey() throws {
        try #require(FFmpegLocator.ffmpegIsAvailable(), "ffmpeg is a dev prerequisite (Brewfile)")
        let base = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/test", "FAKE_CLIP_LOG": "/tmp/x"]
        let env = try SubprocessEnvironment.mediaTools(inheriting: base)
        let path = try #require(env["PATH"]).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let ffmpegDir = (FFmpegLocator.ffmpegPath as NSString).deletingLastPathComponent
        #expect(path.first == ffmpegDir, "\(path)")
        #expect(path.contains((FFmpegLocator.ffprobePath as NSString).deletingLastPathComponent))
        #expect(!path.contains(""), "no empty entry (an empty entry means the current directory)")
        #expect(Set(path).count == path.count, "each folder once: \(path)")
        #expect(Array(path.suffix(4)) == ["/usr/bin", "/bin", "/usr/sbin", "/sbin"], "the inherited PATH is kept, last")
        #expect(env["HOME"] == "/Users/test" && env["FAKE_CLIP_LOG"] == "/tmp/x")
    }

    @Test func anExecutableOverrideWinsAndItsFolderComesFirst() throws {
        try #require(FFmpegLocator.locate(envVar: FFmpegLocator.ffprobeEnvVar, candidates: FFmpegLocator.ffprobeCandidates) != nil)
        let dir = try BackgroundFixtures.scratch("ffmpeg-override")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("ffmpeg")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let env = try SubprocessEnvironment.mediaTools(inheriting: ["PATH": "/usr/bin", FFmpegLocator.ffmpegEnvVar: tool.path])
        #expect(env["PATH"]?.hasPrefix(dir.path + ":") == true, "\(env["PATH"] ?? "-")")
    }

    @Test func noFFmpegAnywhereIsRefusedNamingTheToolAndEveryPlaceLooked() {
        #expect {
            _ = try SubprocessEnvironment.mediaTools(inheriting: ["PATH": "/usr/bin"], fileManager: NoExecutablesFileManager())
        } throws: { error in
            guard let words = (error as? Refusal)?.words else { return false }
            return words.hasPrefix("ffmpeg is not on this Mac") && words.contains("VS_FFMPEG_PATH (unset)")
                && FFmpegLocator.ffmpegCandidates.allSatisfy(words.contains) && words.contains("brew install ffmpeg")
        }
        #expect {
            _ = try SubprocessEnvironment.mediaTools(inheriting: [FFmpegLocator.ffmpegEnvVar: "/nope/ffmpeg"], fileManager: NoExecutablesFileManager())
        } throws: { error in
            (error as? Refusal)?.words.contains("VS_FFMPEG_PATH=/nope/ffmpeg (not executable)") == true
        }
    }

    // MARK: Codex #232 reds (2026-11-04)

    /// Executable stand-ins named `names` in `dir` (each prints its own path).
    static func tools(_ dir: URL, _ names: [String]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            let tool = dir.appendingPathComponent(name)
            try Data("#!/bin/sh\necho \"$0\"\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
    }

    /// The first executable `name` on `path`, as a bare-name lookup would find it.
    static func which(_ name: String, on path: String) -> String? {
        path.split(separator: ":").map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Codex #232 F2: ffmpeg in /A (beside an OLD ffprobe), ffprobe overridden to /B —
    /// a PATH of /A:/B runs /A/ffprobe. Either each bare name finds its resolved
    /// tool, or the environment is refused; never the wrong binary.
    @Test func conflictingFoldersNeverHandTheWorkerTheWrongBinary() throws {
        let root = try BackgroundFixtures.scratch("tools-conflict")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        try Self.tools(a, ["ffmpeg", "ffprobe"])
        try Self.tools(b, ["ffprobe"])
        let base = ["PATH": "/usr/bin", FFmpegLocator.ffmpegEnvVar: a.appendingPathComponent("ffmpeg").path,
                    FFmpegLocator.ffprobeEnvVar: b.appendingPathComponent("ffprobe").path]
        do {
            let env = try SubprocessEnvironment.mediaTools(inheriting: base)
            let path = env["PATH"] ?? ""
            #expect(Self.which("ffmpeg", on: path) == a.appendingPathComponent("ffmpeg").path, "\(path)")
            #expect(Self.which("ffprobe", on: path) == b.appendingPathComponent("ffprobe").path, "a bare ffprobe runs the stale /A/ffprobe: \(path)")
        } catch let refusal as Refusal {
            #expect(refusal.words.contains("ffprobe"), "\(refusal.words)")
        }
    }

    /// Codex #232 F2: an override not named `ffmpeg` cannot be reached by a bare `ffmpeg`.
    @Test func anOverrideWithAnotherNameIsRefusedNotIgnored() throws {
        let root = try BackgroundFixtures.scratch("tools-name")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.tools(root, ["ffmpeg-custom", "ffprobe"])
        let base = ["PATH": "/usr/bin", FFmpegLocator.ffmpegEnvVar: root.appendingPathComponent("ffmpeg-custom").path,
                    FFmpegLocator.ffprobeEnvVar: root.appendingPathComponent("ffprobe").path]
        #expect(throws: Refusal.self) { _ = try SubprocessEnvironment.mediaTools(inheriting: base) }
    }

    /// Codex #232 F3: every PATH entry is absolute and non-empty — no `./bin`, no trailing ":".
    @Test func everyEntryIsAbsoluteAndNonEmpty() throws {
        let root = try BackgroundFixtures.scratch("tools-abs")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.tools(root, ["ffmpeg", "ffprobe"])
        let base = ["PATH": "./bin:/usr/bin::", FFmpegLocator.ffmpegEnvVar: root.appendingPathComponent("ffmpeg").path,
                    FFmpegLocator.ffprobeEnvVar: root.appendingPathComponent("ffprobe").path]
        let parts = try #require(try SubprocessEnvironment.mediaTools(inheriting: base)["PATH"])
            .split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        #expect(parts.allSatisfy { $0.hasPrefix("/") }, "\(parts)")
        let app = SubprocessEnvironment.augmentedPath(inheriting: "/usr/bin:")
        #expect(!app.hasSuffix(":") && !app.contains("::"), "\(app)")
    }

    /// Codex #232 F3: a tool in a folder whose name holds ":" cannot be put on PATH — refused.
    @Test func aToolFolderWithAColonIsRefused() throws {
        let root = try BackgroundFixtures.scratch("tools-colon")
        defer { try? FileManager.default.removeItem(at: root) }
        let odd = root.appendingPathComponent("A:B")
        try Self.tools(odd, ["ffmpeg", "ffprobe"])
        let base = ["PATH": "/usr/bin", FFmpegLocator.ffmpegEnvVar: odd.appendingPathComponent("ffmpeg").path,
                    FFmpegLocator.ffprobeEnvVar: odd.appendingPathComponent("ffprobe").path]
        #expect(throws: Refusal.self) { _ = try SubprocessEnvironment.mediaTools(inheriting: base) }
    }
}
