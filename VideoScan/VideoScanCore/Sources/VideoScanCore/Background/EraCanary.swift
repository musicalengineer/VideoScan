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
        let made = Self.runBlocking(ffmpeg, ["-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=2",
                                             "-c:v", "mpeg4", "-q:v", "5", clip.path], environment: environment)
        guard made == nil else {
            throw Refusal("era: ffmpeg (\(ffmpeg)) cannot make a 2 s synthetic clip — the tool is broken, not the files; "
                          + "refused at START, nothing counted against any file: \(made ?? "")")
        }
        if let why = stillVerdict(Self.runBlocking(ffmpeg, stillArguments, environment: environment)) {
            throw Refusal("era: ffmpeg (\(ffmpeg)) cannot rip a still from a synthetic clip — the tool is broken, not the files; "
                          + "refused at START, nothing counted against any file: \(why)")
        }
    }

    /// nil when the tool rips a still from the synthetic clip (bench.py's own filter), else ffmpeg's words.
    /// Async (2026-11-21): the job calls this mid-run from an `async`
    /// function, so it AWAITS the runner — an async caller never parks a
    /// cooperative-pool thread on the blocking bridge.
    public func toolWorks(environment: [String: String]) async -> String? {
        // Detached from the caller's cancellation, as the blocking form
        // was: a cancelled job must not read its own SIGTERM of ffmpeg as
        // "the tool is broken". The cap bounds it.
        let (tool, arguments, cap) = (ffmpeg, stillArguments, Self.capSeconds)
        let result = await TaskTreeScope.detached {
            await ProcessRunner.runProcess(executable: tool, arguments: arguments, environment: environment,
                                           stdoutLimitBytes: 0, deadlineSeconds: cap)
        }.value
        return Self.$capSeconds.withValue(cap) { stillVerdict(Self.words(for: result, tool: ffmpeg)) }
    }

    private var still: URL { clip.deletingLastPathComponent().appendingPathComponent("still.png") }

    private var stillArguments: [String] {
        let vf = "scale=448:448:force_original_aspect_ratio=decrease,pad=448:448:(ow-iw)/2:(oh-ih)/2:color=black"
        return ["-nostdin", "-loglevel", "error", "-y", "-ss", "1.000", "-i", clip.path, "-frames:v", "1", "-vf", vf, still.path]
    }

    /// The still command's own words if it failed; else whether a still was really written. Removes the still.
    private func stillVerdict(_ commandFailure: String?) -> String? {
        defer { try? FileManager.default.removeItem(at: still) }
        if let commandFailure { return commandFailure }
        let size = (try? FileManager.default.attributesOfItem(atPath: still.path)[.size] as? NSNumber)?.intValue ?? 0
        return size > 0 ? nil : "ffmpeg exited 0 and wrote no still"
    }

    /// Did the worker's record for the synthetic clip carry at least one answered model call?
    public static func modelAnswered(_ record: Data) -> Bool {
        EraRecordMapper.answeredCalls(record) > 0
    }

    /// nil on exit 0, else the last stderr line (or the exit status). 60 s cap.
    ///
    /// Through ProcessRunner (2026-11-21; it was a hand-rolled `Process()`
    /// with a usleep poll): same executable, argv and environment; stdout is
    /// still discarded (limit 0); the 60 s cap is the runner's deadline, which
    /// now also escalates SIGTERM → SIGKILL → abandon instead of sending one
    /// SIGTERM and walking away. Blocking, as before — the callers are a
    /// synchronous init (once per job, at START); the job-time check is
    /// `toolWorks`, which awaits.
    /// Memory: at most 256 KB of the tool's stderr (`-loglevel error`: a line
    /// or two).
    static func runBlocking(_ tool: String, _ args: [String], environment: [String: String]) -> String? {
        words(for: ProcessRunner.runProcessBlocking(executable: tool, arguments: args, environment: environment,
                                                    stdoutLimitBytes: 0, deadlineSeconds: capSeconds), tool: tool)
    }

    /// One command's result as nil (it worked) or why not.
    static func words(for result: ProcessRunner.Result, tool: String) -> String? {
        // Exit status first: a child that finished in the instant the
        // deadline fired did its work (ProcessRunner.Result.timedOut's note).
        if result.launched, result.exitCode == 0 { return nil }
        // Before `launched`: the blocking bridge's own bound reports
        // timedOut with no launch evidence.
        if result.timedOut { return "\(tool) ran past \(Int(capSeconds)) s" }
        guard result.launched else { return "could not start \(tool): \(result.stderr)" }
        let last = result.stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        return String((last ?? "exit \(result.exitCode)").prefix(300))
    }

    /// The cap on one canary command. Task-local so a test of the "ran past"
    /// row does not wait a minute; production never binds it.
    /// (C++: a thread_local override that follows the coroutine.)
    @TaskLocal static var capSeconds: Double = 60
}
