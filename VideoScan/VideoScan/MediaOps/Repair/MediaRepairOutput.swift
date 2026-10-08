import Foundation

// MARK: - Where a repair's NEW file goes (Rick 2026-10-08)
//
// The rule, non-negotiable: a fix never modifies, moves or deletes the
// original. The new file is `<stem>_remuxed.<ext>` / `<stem>_repaired.<ext>`
// beside the original — EXCEPT when the original's drive is protected
// (the delete-protection predicate: the Master Archive tree or volume, an
// archive volume that can't be told apart, a drive marked Read only).
// Then the person picks a folder (a save panel defaulting to ~/Movies),
// and a protected folder is refused. Pure: the protection test is a
// closure, so the tests stub it.

enum MediaRepairOutput {

    /// Sound codecs an .mp4 can carry next to H.264 (ffmpeg's mp4 muxer).
    static let mp4SoundCodecs: Set<String> = ["aac", "mp3", "ac3", "eac3", "alac", "opus", "flac"]

    /// The new file's extension. A remux keeps the container (a stream
    /// copy changes nothing but the layout). The frame repair re-encodes
    /// the picture to H.264 and copies the sound, so it keeps .mkv (holds
    /// anything), keeps .mp4/.m4v when the sound fits, else .mov.
    static func fileExtension(for fix: MediaRepairFix, sourceExtension: String, audioCodec: String) -> String {
        let ext = sourceExtension.lowercased()
        guard fix == .removeRepeatedFrames else { return sourceExtension }
        switch ext {
        case "mkv", "mov":
            return ext
        case "mp4", "m4v":
            let sound = audioCodec.trimmingCharacters(in: .whitespaces).lowercased()
            return sound.isEmpty || mp4SoundCodecs.contains(sound) ? ext : "mov"
        default:
            return "mov"
        }
    }

    /// `<stem><suffix>.<ext>`.
    static func fileName(sourcePath: String, fix: MediaRepairFix, audioCodec: String) -> String {
        let src = URL(fileURLWithPath: sourcePath)
        let stem = src.deletingPathExtension().lastPathComponent
        let ext = fileExtension(for: fix, sourceExtension: src.pathExtension, audioCodec: audioCodec)
        return ext.isEmpty ? "\(stem)\(fix.outputSuffix)" : "\(stem)\(fix.outputSuffix).\(ext)"
    }

    /// Where the new file should go.
    enum Destination: Equatable {
        /// Beside the original (its drive is not protected).
        case beside(URL)
        /// Ask with a save panel; never the protected drive.
        case ask(defaultDirectory: URL, suggestedName: String, why: String)
    }

    /// `protectionNote` is the delete gate's sentence for the original's
    /// path (nil = not protected).
    static func destination(sourcePath: String, fix: MediaRepairFix, audioCodec: String,
                            protectionNote: String?, workspace: URL) -> Destination {
        let name = fileName(sourcePath: sourcePath, fix: fix, audioCodec: audioCodec)
        guard let protectionNote else {
            return .beside(URL(fileURLWithPath: sourcePath).deletingLastPathComponent().appendingPathComponent(name))
        }
        return .ask(defaultDirectory: workspace, suggestedName: name,
                    why: "The original is protected (it \(protectionNote)), so the repaired copy can't go next to it. Choose where to save it.")
    }

    /// Refuses a chosen output that would land on a protected drive or on
    /// the original itself; nil = fine. `isProtected` is the delete gate
    /// for a path (nil = not protected).
    static func refusal(forChosen output: URL, sourcePath: String,
                        isProtected: (String) -> String?) -> String? {
        let out = output.standardizedFileURL.path
        if out == URL(fileURLWithPath: sourcePath).standardizedFileURL.path {
            return "That is the original file — a repair always writes a new file."
        }
        if let note = isProtected(out) {
            return "That folder is protected (it \(note)). Choose a folder on another drive."
        }
        return nil
    }

    /// The default folder for a protected original: ~/Movies (the internal
    /// drive), the Transcode sheet's first-use default.
    static var defaultWorkspace: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }
}
