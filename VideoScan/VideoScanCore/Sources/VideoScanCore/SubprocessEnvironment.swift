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
    /// inherited PATH falls back to the POSIX default, so the result never
    /// ends in ":" (an empty entry means "the current directory").
    public static func augmentedPath(inheriting inheritedPath: String?) -> String {
        let inherited = (inheritedPath?.isEmpty == false ? inheritedPath : nil) ?? posixDefaultPath
        return (homebrewBinFolders + [inherited]).joined(separator: ":")
    }

    /// `base` (the parent's environment) with a PATH on which a bare
    /// `ffmpeg` and `ffprobe` are the ones FFmpegLocator resolves: their
    /// folders first, then `augmentedPath` of the inherited PATH, each folder
    /// once. Throws a Refusal naming the missing tool and where it looked.
    public static func mediaTools(inheriting base: [String: String],
                                  fileManager: FileManager = .default) throws -> [String: String] {
        let tools = [("ffmpeg", FFmpegLocator.ffmpegEnvVar, FFmpegLocator.ffmpegCandidates),
                     ("ffprobe", FFmpegLocator.ffprobeEnvVar, FFmpegLocator.ffprobeCandidates)]
        var folders: [String] = []
        for (name, envVar, candidates) in tools {
            guard let path = FFmpegLocator.locate(envVar: envVar, candidates: candidates, environment: base, fileManager: fileManager) else {
                let override = base[envVar].map { "\(envVar)=\($0) (not executable)" } ?? "\(envVar) (unset)"
                throw Refusal("\(name) is not on this Mac — looked at \(override), \(candidates.joined(separator: ", ")); "
                              + "install it with `brew install ffmpeg` (the repo's Brewfile) or set \(envVar)")
            }
            folders.append((path as NSString).deletingLastPathComponent)
        }
        var seen = Set<String>()
        let path = (folders + augmentedPath(inheriting: base["PATH"]).split(separator: ":").map(String.init))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        var out = base
        out["PATH"] = path.joined(separator: ":")
        return out
    }
}
