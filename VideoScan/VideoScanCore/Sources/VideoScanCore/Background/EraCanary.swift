// EraCanary.swift — VideoScanCore/Background
//
// "Is it the file, or is it the Mac?" (Fable review 2026-11-04). A try is
// counted against a FILE (EraAttemptStore; three tries and the file is given
// up for good) only when the tools and the model are shown to work:
//   * the TOOL canary: the worker's own `ffmpeg` (the one a bare name finds on
//     the worker's PATH) encodes a 2 s synthetic clip and rips one still from
//     it with the same filter bench.py uses. Run at START (a broken ffmpeg
//     refuses the job: a Homebrew upgrade that broke a dylib must not give up
//     every file in the catalog) and again before a "no frame would decode" try.
//   * the MODEL canary: the worker analyzes that synthetic clip; at least one
//     window or still must come back answered. Run once per job, at the first
//     model-side no-verdict (a timeout, a worker death, windows never
//     answered) of a unit that proved nothing itself, and again after three
//     such units in a row. If it fails, nothing is counted and the job stops
//     (fail fast → the kind holds, with the words).
// The synthetic clip lives at <state root>/canary/canary.mp4 (testsrc; no
// family media), made once per job.
//
// C++ reading: a self-test object; `toolWorks()` is a POST, run before trusting a result.

import Foundation

public struct EraCanary: Sendable {
    public let ffmpeg: String
    public let clip: URL

    /// The `ffmpeg` a bare name runs on `environment`'s PATH (the worker's), or a refusal.
    public static func ffmpeg(onPathOf environment: [String: String]) throws -> String {
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        guard let found = folders.map({ "\($0)/ffmpeg" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Refusal("era: no ffmpeg on the worker's PATH (\(environment["PATH"] ?? "unset")) — refused at START")
        }
        return found
    }

    /// Makes the synthetic clip and proves the tool on it; throws a Refusal in words when the tool is broken.
    public init(environment: [String: String], stateRoot: URL) throws {
        ffmpeg = try Self.ffmpeg(onPathOf: environment)
        let dir = stateRoot.appendingPathComponent("canary", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        clip = dir.appendingPathComponent("canary.mp4")
        let made = Self.run(ffmpeg, ["-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=2",
                                     "-c:v", "mpeg4", "-q:v", "5", clip.path], environment: environment)
        guard made == nil else {
            throw Refusal("era: ffmpeg (\(ffmpeg)) cannot make a 2 s synthetic clip — the tool is broken, not the files; "
                          + "refused at START, nothing counted against any file: \(made ?? "")")
        }
        if let why = toolWorks(environment: environment) {
            throw Refusal("era: ffmpeg (\(ffmpeg)) cannot rip a still from a synthetic clip — the tool is broken, not the files; "
                          + "refused at START, nothing counted against any file: \(why)")
        }
    }

    /// nil when the tool rips a still from the synthetic clip (bench.py's own filter), else ffmpeg's words.
    public func toolWorks(environment: [String: String]) -> String? {
        let still = clip.deletingLastPathComponent().appendingPathComponent("still.png")
        defer { try? FileManager.default.removeItem(at: still) }
        let vf = "scale=448:448:force_original_aspect_ratio=decrease,pad=448:448:(ow-iw)/2:(oh-ih)/2:color=black"
        if let why = Self.run(ffmpeg, ["-nostdin", "-loglevel", "error", "-y", "-ss", "1.000", "-i", clip.path, "-frames:v", "1", "-vf", vf, still.path],
                              environment: environment) { return why }
        let size = (try? FileManager.default.attributesOfItem(atPath: still.path)[.size] as? NSNumber)?.intValue ?? 0
        return size > 0 ? nil : "ffmpeg exited 0 and wrote no still"
    }

    /// Did the worker's record for the synthetic clip carry at least one answered model call?
    public static func modelAnswered(_ record: Data) -> Bool {
        EraRecordMapper.answeredCalls(record) > 0
    }

    /// nil on exit 0, else the last stderr line (or the exit status). 60 s cap.
    static func run(_ tool: String, _ args: [String], environment: [String: String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.environment = environment
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { return "could not start \(tool): \(error)" }
        let deadline = Date().addingTimeInterval(60)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return "\(tool) ran past 60 s" }
        let words = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus != 0 else { return nil }
        let last = words.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        return String((last ?? "exit \(p.terminationStatus)").prefix(300))
    }
}
