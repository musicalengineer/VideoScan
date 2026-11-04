// SubprocessEnvironment.swift (VideoScanCore)
// ONE SENTENCE: the one builder of the environment a VideoScan child process
// (a Python worker, a model script) is started with, so it finds Homebrew's
// tools however its parent was launched — moved here from the app target's
// Shared/SubprocessEnv.swift (2026-11-04) so VideoScan Background uses the
// same rule; the app's `augmentedPathWithHomebrew` forwards here.
//
// Why: Finder, Xcode and launchd give a process a PATH with no Homebrew
// (launchd: /usr/bin:/bin:/usr/sbin:/sbin). A child that runs `ffmpeg` or
// `ffprobe` by bare name (bench.py, mlx-whisper, cluster_faces.py) then
// fails with `[Errno 2] No such file or directory: 'ffmpeg'` — on every file
// (2026-11-03: era job 76A5CC1E, 523 of 523 units).
//
// `mediaTools` is the strict form for a job that cannot work without
// ffmpeg/ffprobe: it resolves both through FFmpegLocator (the one locator —
// VS_FFMPEG_PATH / VS_FFPROBE_PATH, then the Homebrew/system candidates),
// puts their folders first on PATH, and REFUSES in words naming the tool and
// every place it looked when one is missing — at plan/START, never per unit.
//
// Pure apart from the FileManager it is handed. Memory: one copy of the
// environment dictionary.

import Foundation

public enum SubprocessEnvironment {

    /// Apple Silicon first, then Intel / older installs.
    public static let homebrewBinFolders = ["/opt/homebrew/bin", "/usr/local/bin"]
    /// What launchd and a bare `Process` give when there is no PATH at all.
    public static let posixDefaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// The Homebrew folders ahead of the inherited PATH. A nil or empty
    /// inherited PATH falls back to the POSIX default; empty entries ("a::b",
    /// a trailing ":") are dropped, since an empty entry means "the current
    /// directory".
    public static func augmentedPath(inheriting inheritedPath: String?) -> String {
        let inherited = (inheritedPath ?? "").split(separator: ":").map(String.init)
        return (homebrewBinFolders + (inherited.isEmpty ? posixDefaultPath.split(separator: ":").map(String.init) : inherited))
            .joined(separator: ":")
    }

    /// `base` (the parent's environment) with a PATH on which a bare
    /// `ffmpeg` and `ffprobe` are EXACTLY the ones FFmpegLocator resolves:
    /// their folders first, then `augmentedPath` of the inherited PATH, each
    /// folder once, absolute folders only; every other key kept. Refuses —
    /// never hands the child a PATH that runs another binary — when a tool
    /// is missing, when an override is not named after its tool or is not an
    /// absolute path, when a folder holds ":", or when the folders conflict
    /// (ffmpeg's folder holds a different ffprobe than the one resolved;
    /// Codex #232 F2/F3).
    public static func mediaTools(inheriting base: [String: String],
                                  fileManager: FileManager = .default) throws -> [String: String] {
        let tools = [("ffmpeg", FFmpegLocator.ffmpegEnvVar, FFmpegLocator.ffmpegCandidates),
                     ("ffprobe", FFmpegLocator.ffprobeEnvVar, FFmpegLocator.ffprobeCandidates)]
        var resolved: [(name: String, envVar: String, path: String)] = []
        for (name, envVar, candidates) in tools {
            guard let found = FFmpegLocator.locate(envVar: envVar, candidates: candidates, environment: base, fileManager: fileManager) else {
                let override = base[envVar].map { "\(envVar)=\($0) (not executable)" } ?? "\(envVar) (unset)"
                throw Refusal("\(name) is not on this Mac — looked at \(override), \(candidates.joined(separator: ", ")); "
                              + "install it with `brew install ffmpeg` (the repo's Brewfile) or set \(envVar)")
            }
            let path = (found as NSString).standardizingPath
            guard path.hasPrefix("/"), (path as NSString).lastPathComponent == name else {
                throw Refusal("\(name): \(envVar)=\(found) cannot be what a bare `\(name)` runs — point it at an absolute path to a file named \(name)")
            }
            guard !(path as NSString).deletingLastPathComponent.contains(":") else {
                throw Refusal("\(name): its folder \((path as NSString).deletingLastPathComponent) holds \":\", which PATH cannot carry — move it or set \(envVar)")
            }
            resolved.append((name, envVar, path))
        }
        var seen = Set<String>()
        let folders = resolved.map { ($0.path as NSString).deletingLastPathComponent }
        let path = (folders + augmentedPath(inheriting: base["PATH"]).split(separator: ":").map(String.init))
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
            .joined(separator: ":")
        // The proof: what a bare-name lookup on this PATH would run is the resolved tool.
        for tool in resolved {
            let first = path.split(separator: ":").map { "\($0)/\(tool.name)" }.first { fileManager.isExecutableFile(atPath: $0) }
            // Same binary = same file after symlinks (Homebrew's bin/ and opt/ffmpeg/bin/
            // are links to one Cellar file; Codex #233 F1), not the same spelling.
            guard let first, identity(first) == identity(tool.path) else {
                throw Refusal("\(tool.name): the resolved \(tool.path) would be shadowed on the worker's PATH by \(first ?? "nothing") "
                              + "(ffmpeg and ffprobe in different folders, each beside another copy) — put both in one folder, or set \(tool.envVar) to the one beside the other tool")
            }
        }
        var out = base
        out["PATH"] = path
        return out
    }

    /// A file's identity for "is this the binary a bare name runs": its path
    /// with every symlink resolved.
    static func identity(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
