import Darwin
import Foundation
import os

// MARK: - Repair Now's engine: one recipe → one new file (Rick 2026-10-08)
//
// "Make a fixed copy of this damaged file next to it, and show me what
// changed." This file is the "make a fixed copy" half; MediaRepairJob is
// the MFO row around it and the "show me" half.
//
// The rules, in order — each one is a test in MediaRepairEngineTests:
//   1. REFUSE BEFORE THE FIRST WRITE. Every check that can say no — nothing
//      to fix, the original offline, the target name taken, the target
//      folder protected (the delete gate: Master Archive tree / volume,
//      Read-only marks; plus any volume named FamilyArchive, gate or no
//      gate), the folder not writable, not enough space, ffmpeg missing,
//      no justified frame rate (MediaRepairPicturePlan) — runs before the
//      partial is reserved.
//   2. ffmpeg writes ONE reserved partial (`<stem>.<8 hex>.vs-partial.<ext>`,
//      O_EXCL, registered live) beside the target. The original is opened
//      read-only by ffmpeg / ffprobe and by nothing else.
//   3. PROVE before publishing — "structural checks + sampled decode",
//      never "fully verified". A lossless remux must match the original
//      packet for packet per stream (MediaRepairParity.compare); a pass that
//      re-encodes must keep its streams, its planned length and (picture)
//      its colour tags / aspect / chroma (MediaRepairParity.compareRewritten).
//      Then ≤ 5 short windows of the copy are decoded.
//   4. PUBLISH with the one no-clobber rename (ExclusivePublish:
//      RENAME_EXCL, else link(2), else refuse). A name that appeared while
//      we worked is NEVER written over and NEVER published beside — the
//      copy is kept unpublished and the run fails, saying where it is.
//      Never `replaceItemAt` (the Sandbox rename wedge).
//   5. On failure the partial is KEPT unpublished (protected `.vs-kept.`
//      name — a damaged source's partial output may be the best copy there
//      is), unless ffmpeg wrote nothing at all. On cancel it is removed
//      (the person stopped it; nothing worth keeping).
//
// Memory: ffmpeg / ffprobe do all media I/O. In process: the packet
// census's per-stream counters (O(streams)), ≤ 256 KB of ffmpeg stderr, a few KB of probe JSON. < 2 MB worst
// case, whatever the file size.
//
// (For Rick: a caseless `enum` with static funcs ≈ a C++ namespace of free
// functions. `@concurrent` ≈ "always run on the worker pool, never on the
// caller's thread" — see project_approachable_concurrency_trap.)

private let repairLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "repair")

/// How one Repair Now ended. Exactly one; only `.repaired` is success.
enum MediaRepairOutcome: Equatable, Sendable {
    /// Published at `output` AND the proof passed. `proof` says what matched.
    case repaired(output: URL, proof: String)
    /// Said no before writing anything.
    case refused(reason: String)
    /// Something went wrong after the first write. Nothing was published;
    /// `keptAt` is where the unpublished copy is (nil = nothing kept).
    case failed(reason: String, keptAt: URL?)
    /// The person stopped it; this run's partial was removed.
    case cancelled

    var isSuccess: Bool {
        if case .repaired = self { return true }
        return false
    }
}

/// Everything one run needs, captured on the main actor.
struct MediaRepairRequest: Sendable {
    let sourcePath: String
    let sourceSizeBytes: Int64
    let sourceDurationSeconds: Double
    /// The ONE file this run may create.
    let output: URL
    let recipe: MediaRepairRecipe
    /// The delete gate's sentence for the output path, asked on the main
    /// actor (`bulkDeleteRefusal(forPath:)`); nil = not protected.
    let outputProtectionNote: String?
    /// The same gate re-asked on the disk thread (volume UUID, mount
    /// identity); nil = no archive designated and no Read-only marks.
    let archiveCheck: ArchiveRemovalCheck?
    /// Pictures Remove repeated frames keeps, counted by the sheet at plan
    /// time (saves a second decode); nil = the engine counts them itself.
    var plannedPictureFrames: Int? = nil
}

/// The steps a run walks through, for the row's "N of M".
enum MediaRepairPhase: Int, Sendable, CaseIterable {
    case plan, write, prove, publish

    var step: String {
        switch self {
        case .plan: return "reading the picture's frame rate and colour"
        case .write: return "writing the repaired copy"
        case .prove: return "checking the copy (structure + sampled decode)"
        case .publish: return "saving the copy"
        }
    }
}

/// What the disk says before anything is written. Plain values so the
/// refusal rule is a pure function the tests drive directly.
struct MediaRepairPreflightFacts: Equatable, Sendable {
    var sourceExists = true
    /// lstat: any kind of entry at the target name (file, folder, link).
    var outputExists = false
    var outputFolderExists = true
    var outputFolderWritable = true
    /// nil = unknown (don't refuse on a guess).
    var freeBytes: Int64?
    /// The off-main re-ask of the delete gate for the output path.
    var outputGateNote: String?
    /// nil = ffmpeg and ffprobe are both present.
    var missingTool: String?
}

enum MediaRepairEngine {

    /// What "checked" means here — said exactly, never "fully verified"
    /// (codex consult #6).
    static let verificationLevel = "structural checks + sampled decode"

    /// Muxer / index headroom on top of the size estimate.
    static let headroomBytes: Int64 = 64 << 20

    /// ffmpeg / ffprobe locations. Test seam: point ffmpeg at a tool that
    /// fails to prove the failure path.
    struct Tools: Sendable {
        var ffmpeg: String
        var ffprobe: String
        static var located: Tools { Tools(ffmpeg: ToolLocator.ffmpegPath, ffprobe: ToolLocator.ffprobePath) }
    }

    /// `fraction` nil = a heartbeat (the stall watchdog's tick) with no
    /// position to report.
    typealias Progress = @Sendable (MediaRepairPhase, Double?) -> Void

    // MARK: Refusals (pure)

    /// A rough upper bound on the new file: the original's size (a stream
    /// copy is the same size; repeated frames removed are far smaller),
    /// plus uncompressed stereo PCM when the sound is rebuilt.
    static func requiredFreeBytes(recipe: MediaRepairRecipe, sourceBytes: Int64, durationSeconds: Double) -> Int64 {
        let pcm: Int64 = recipe.sound == .rebuild ? Int64(max(0, durationSeconds) * 192_000) : 0
        return max(0, sourceBytes) + pcm + headroomBytes
    }

    /// A volume named FamilyArchive ("FamilyArchive", "FamilyArchive 1") is
    /// never a write target — whether or not it is the designated Master
    /// Archive (belt and braces under the delete gate).
    static func isFamilyArchivePath(_ path: String) -> Bool {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        // The volume is the component after the LAST "Volumes": covers
        // "/Volumes/<name>/…" and the firmlink "/System/Volumes/Data/Volumes/<name>/…".
        guard let i = parts.lastIndex(of: "Volumes"), i + 1 < parts.count else { return false }
        let volume = parts[i + 1]
        return volume == "FamilyArchive" || volume.hasPrefix("FamilyArchive ")
    }

    /// Why this run must not start; nil = go. Every reason a run can be
    /// refused, in one place, in the order the person would want to hear.
    static func refusal(_ req: MediaRepairRequest, facts: MediaRepairPreflightFacts) -> String? {
        if req.recipe.isEmpty {
            return "There is nothing Repair can fix in this file."
        }
        if !facts.sourceExists {
            return "The original isn't reachable — its drive may be disconnected. Nothing was written."
        }
        let out = req.output.standardizedFileURL.path
        if out == URL(fileURLWithPath: req.sourcePath).standardizedFileURL.path {
            return "That is the original file — a repair always writes a new file."
        }
        if isFamilyArchivePath(out) {
            return "The repaired copy can't be saved on FamilyArchive — the archive is only changed by archive actions. Choose a folder on another drive."
        }
        if let note = req.outputProtectionNote ?? facts.outputGateNote {
            return "That folder is protected (it \(note)). Choose a folder on another drive."
        }
        if facts.outputExists {
            return "A file named \(req.output.lastPathComponent) is already there. VideoScan never writes over a file — rename or move that one, then try again."
        }
        if !facts.outputFolderExists {
            return "The folder for the repaired copy isn't there any more."
        }
        if !facts.outputFolderWritable {
            return "The folder for the repaired copy is read-only. Choose a folder on another drive."
        }
        let needed = requiredFreeBytes(recipe: req.recipe, sourceBytes: req.sourceSizeBytes,
                                       durationSeconds: req.sourceDurationSeconds)
        if let free = facts.freeBytes, free < needed {
            return "Not enough free space for the repaired copy — it needs about \(MediaBytes.display(needed)), and \(MediaBytes.display(free)) is free."
        }
        if let tool = facts.missingTool {
            return "\(tool) isn't installed (install it with Homebrew)."
        }
        return nil
    }

    // MARK: Disk facts (reads only)

    static func gatherFacts(_ req: MediaRepairRequest, tools: Tools) -> MediaRepairPreflightFacts {
        let fm = FileManager.default
        var facts = MediaRepairPreflightFacts()
        var st = stat()
        facts.sourceExists = stat(req.sourcePath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
        facts.outputExists = lstat(req.output.path, &st) == 0
        let folder = req.output.deletingLastPathComponent().path
        var isDir: ObjCBool = false
        facts.outputFolderExists = fm.fileExists(atPath: folder, isDirectory: &isDir) && isDir.boolValue
        facts.outputFolderWritable = fm.isWritableFile(atPath: folder)
        facts.freeBytes = (try? URL(fileURLWithPath: folder)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        facts.outputGateNote = req.archiveCheck?.refusalNote(forPath: req.output.path)
        if tools.ffmpeg.isEmpty || !fm.isExecutableFile(atPath: tools.ffmpeg) {
            facts.missingTool = "ffmpeg"
        } else if tools.ffprobe.isEmpty || !fm.isExecutableFile(atPath: tools.ffprobe) {
            facts.missingTool = "ffprobe"
        }
        return facts
    }

    // MARK: The run

    /// Preflight's answer: go (with the justified picture plan when the recipe
    /// needs one), or stop with an outcome — nothing written either way.
    enum Preflight: Equatable, Sendable {
        /// `picture` = the justified re-encode plan (repeated frames only).
        case go(picture: MediaRepairPicturePlan?)
        case stop(MediaRepairOutcome)
    }

    @concurrent
    static func run(_ req: MediaRepairRequest, tools: Tools = .located,
                    control: ProcessControl?, progress: @escaping Progress) async -> MediaRepairOutcome {
        let picture: MediaRepairPicturePlan?
        switch await preflight(req, tools: tools, control: control, progress: progress) {
        case .go(let plan): picture = plan
        case .stop(let outcome): return outcome
        }
        // ---- First write: this run's own reserved partial.
        let partial: MediaRepairPartial
        do {
            partial = try MediaRepairPartial(reservingFor: req.output)
        } catch {
            return .failed(reason: "Could not start the repaired copy: \(error.localizedDescription)", keptAt: nil)
        }
        defer { partial.release() }
        if let stop = await partial.write(req, tools: tools, picture: picture, control: control, progress: progress) {
            return stop
        }
        progress(.prove, nil)
        switch await partial.prove(req, picture: picture, control: control, heartbeat: { progress(.prove, nil) }) {
        case .stop(let outcome): return outcome
        case .passed(let detail):
            progress(.publish, nil)
            return partial.publish(as: req.output, proof: detail)
        }
    }

    /// Every refusal, then (for repeated frames) the justified picture plan — all
    /// before the first write.
    static func preflight(_ req: MediaRepairRequest, tools: Tools, control: ProcessControl?,
                          progress: @escaping Progress) async -> Preflight {
        let name = (req.sourcePath as NSString).lastPathComponent
        if let why = refusal(req, facts: gatherFacts(req, tools: tools)) {
            repairLog.notice("repair REFUSED \(name, privacy: .public): \(why, privacy: .public)")
            return .stop(.refused(reason: why))
        }
        guard req.recipe.picture == .removeRepeatedFrames else {
            return Task.isCancelled ? .stop(.cancelled) : .go(picture: nil)
        }
        progress(.plan, nil)
        let summary: MediaRepairStreamSummary
        do {
            summary = try await MediaRepairProbe.summary(path: req.sourcePath, control: control)
        } catch {
            if Task.isCancelled || error is CancellationError { return .stop(.cancelled) }
            return .stop(.refused(reason: "The original's picture couldn't be read (\(error.localizedDescription)). Nothing was written."))
        }
        guard let facts = summary.picture else {
            return .stop(.refused(reason: "This file has no picture to repair. Nothing was written."))
        }
        switch MediaRepairPicturePlan.justify(facts) {
        case .failure(let refusal): return .stop(.refused(reason: refusal.reason))
        case .success(let plan):
            if let stop = await soundAlignmentStop(req, summary: summary, plan: plan, control: control, progress: progress) {
                return .stop(stop)
            }
            return Task.isCancelled ? .stop(.cancelled) : .go(picture: plan)
        }
    }

    /// The sound must line up with the shorter picture (files with sound
    /// only). Counts the kept pictures unless the sheet already did.
    private static func soundAlignmentStop(_ req: MediaRepairRequest, summary: MediaRepairStreamSummary,
                                           plan: MediaRepairPicturePlan, control: ProcessControl?,
                                           progress: @escaping Progress) async -> MediaRepairOutcome? {
        let sound = summary.streams.filter { $0.codecType == "audio" }.map(\.durationSeconds)
        guard !sound.isEmpty else { return nil }
        let kept: Int
        if let planned = req.plannedPictureFrames {
            kept = planned
        } else {
            do {
                kept = try await MediaRepairProbe.keptFrameCount(path: req.sourcePath, control: control,
                                                                 heartbeat: { progress(.plan, nil) })
            } catch {
                if Task.isCancelled || error is CancellationError { return .cancelled }
                return .refused(reason: "The real pictures couldn't be counted (\(error.localizedDescription)). Nothing was written.")
            }
        }
        guard let why = MediaRepairSoundAlignment.refusal(soundDurations: sound, keptFrames: kept, rate: plan.rate) else {
            return nil
        }
        return .refused(reason: "Remove repeated frames isn't available: \(why). Nothing was written.")
    }
}

// MARK: - The one file a run writes

/// This run's reserved partial and everything that can happen to it:
/// written by ffmpeg, proved against the original, then published under
/// the target name — or kept unpublished (failure) or removed (cancel).
/// (≈ a C++ RAII-ish handle: the owner calls `release()` on every exit.)
struct MediaRepairPartial: Sendable {
    let url: URL

    init(reservingFor output: URL) throws {
        url = try DerivativeOutputPublish.reservePartial(for: output)
    }

    /// Drop the live reservation (the file, if still here, is either kept
    /// with a protection marker or gone).
    func release() { PartialFileNaming.unregisterLive(url) }

    /// The recipe's one ffmpeg pass into the partial. nil = written.
    @concurrent
    func write(_ req: MediaRepairRequest, tools: MediaRepairEngine.Tools, picture: MediaRepairPicturePlan?,
               control: ProcessControl?, progress: @escaping MediaRepairEngine.Progress) async -> MediaRepairOutcome? {
        progress(.write, 0)
        let args = req.recipe.ffmpegArgs(input: req.sourcePath, output: url.path, picture: picture)
        repairLog.info("repair write: ffmpeg \(args.joined(separator: " "), privacy: .public)")
        let duration = req.sourceDurationSeconds
        let result = await ProcessRunner.runProcess(
            executable: tools.ffmpeg, arguments: args,
            stderrLine: { line in
                let at = ReformatJob.parseProgressSeconds(line: line)
                progress(.write, at.map { duration > 0 ? min(1, $0 / duration) : 0 })
            },
            control: control)
        if Task.isCancelled { return discard() }
        guard result.exitCode == 0 else {
            let tail = result.stderr.split(separator: "\n").suffix(3).joined(separator: " · ")
            return keep(reason: "ffmpeg stopped with status \(result.exitCode)\(tail.isEmpty ? "" : " — \(tail)")")
        }
        return nil
    }

    enum Proof: Equatable, Sendable {
        case passed(String)
        case stop(MediaRepairOutcome)
    }

    /// Packet parity for a pure stream copy; streams + length for a pass
    /// that re-encodes. Anything but a pass keeps the copy unpublished.
    @concurrent
    func prove(_ req: MediaRepairRequest, picture: MediaRepairPicturePlan?, control: ProcessControl?,
               heartbeat: @escaping @Sendable () -> Void) async -> Proof {
        let verdict: MediaRepairParity
        do {
            verdict = try await Self.parity(req, picture: picture, partial: url, control: control, heartbeat: heartbeat)
        } catch {
            if Task.isCancelled || error is CancellationError { return .stop(discard()) }
            return .stop(keep(reason: "The copy couldn't be checked: \(error.localizedDescription)"))
        }
        if Task.isCancelled { return .stop(discard()) }
        switch verdict {
        case .identical(let detail): return .passed(detail)
        case .different(let why):
            return .stop(keep(reason: "The copy didn't match the original (\(why)), so it was not saved under its name."))
        }
    }

    /// Structure first (packets for a stream copy; streams, tags and
    /// length for a re-encode), then the sampled decode of the copy.
    private static func parity(_ req: MediaRepairRequest, picture: MediaRepairPicturePlan?, partial: URL,
                               control: ProcessControl?,
                               heartbeat: @escaping @Sendable () -> Void) async throws -> MediaRepairParity {
        let structure: MediaRepairParity
        let after = try await MediaRepairProbe.summary(path: partial.path, control: control)
        if req.recipe.isLossless {
            let tallyBefore = try await MediaRepairProbe.streamTallies(path: req.sourcePath, control: control, heartbeat: heartbeat)
            let tallyAfter = try await MediaRepairProbe.streamTallies(path: partial.path, control: control, heartbeat: heartbeat)
            structure = MediaRepairParity.compare(source: tallyBefore, output: tallyAfter)
        } else {
            let before = try await MediaRepairProbe.summary(path: req.sourcePath, control: control)
            structure = MediaRepairParity.compareRewritten(source: before, output: after, recipe: req.recipe, picture: picture)
        }
        guard case .identical(let detail) = structure else { return structure }
        heartbeat()
        if let why = try await MediaRepairProbe.sampledDecodeFailure(path: partial.path, durationSeconds: after.durationSeconds,
                                                                     control: control) {
            return .different(reason: why)
        }
        return .identical(detail: detail + " · " + MediaRepairEngine.verificationLevel)
    }

    /// The one no-clobber rename. A taken name is never written over and
    /// never published beside: the copy is kept and the run fails.
    func publish(as output: URL, proof: String) -> MediaRepairOutcome {
        do {
            guard try DerivativeOutputPublish.renameNoClobber(url.path, output.path) else {
                return keep(reason: "A file named \(output.lastPathComponent) appeared while the copy was being made; VideoScan never writes over a file.")
            }
        } catch {
            return keep(reason: "The copy couldn't be saved under its name: \(error.localizedDescription)")
        }
        repairLog.info("repair published \(output.path, privacy: .public): \(proof, privacy: .public)")
        return .repaired(output: output, proof: proof)
    }

    /// Cancel: remove this run's own partial (name-guarded unlink).
    func discard() -> MediaRepairOutcome {
        do {
            try PartialFileNaming.remove(url)
        } catch {
            repairLog.error("repair: could not remove partial \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return .cancelled
    }

    /// Failure after the first write: keep what ffmpeg wrote, unpublished
    /// and protected from every sweep — unless it wrote nothing.
    func keep(reason: String) -> MediaRepairOutcome {
        var st = stat()
        if lstat(url.path, &st) != 0 || st.st_size == 0 {
            try? PartialFileNaming.remove(url)
            return .failed(reason: reason, keptAt: nil)
        }
        let kept = DerivativeOutputPublish.keepUnpublished(url)
        repairLog.notice("repair FAILED, copy kept unpublished at \(kept.path, privacy: .public): \(reason, privacy: .public)")
        return .failed(reason: reason, keptAt: kept)
    }
}
