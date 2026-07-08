import Combine
import Foundation
import os

// MARK: - Media File Operations (phase 1)
//
// ONE non-modal window hosts every file-by-file operation — combine,
// compare, extract-frames, and future verbs — with parallel background
// processing, per-job cancel (and pause where the operation supports
// it). This file is the model layer:
//
//   - `MediaFileOperationKind`  — which verb a row represents (badge).
//   - `MediaFileOperationState` — running / cancelling / finished /
//     failed / cancelled, with a summary or message payload.
//   - `MediaFileOperationJob`   — the protocol every operation job
//     conforms to so the window's list can render them uniformly.
//   - `MediaFileOperationsCenter` — the app-level registry that owns
//     the jobs, hands out per-volume read gates, and is what the quit
//     guard consults.
//   - `MediaVolumeGatePolicy`   — PURE slot policy (how many compares
//     may read a volume at once, by media tech). No I/O — unit-testable
//     without touching real volumes.
//
// Phase 1 deliberately leaves the existing Combine queue on its own
// machinery (`CombineJobStatus` rows driven by DashboardState): the
// window renders combine rows in their own section alongside new-style
// jobs. Visual unity first, type unity later.

/// File-scope logger — detached job tasks log through this.
private let fileOpsLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                category: "fileOps")

// MARK: - Kind

/// Which verb a job performs. Drives the colored badge capsule in the
/// operations window ("Combine" green, "Compare" blue, "Faces" orange,
/// "Frames" purple).
enum MediaFileOperationKind: String, CaseIterable {
    case combine
    case compare
    /// Vision-scored best-portrait-frames rip ("Extract Facial
    /// Frames…"). The case name predates the verb split — kept as
    /// `.extract` so persisted/test references don't churn; only the
    /// badge text changed.
    case extract
    /// ffmpeg-only frame export ("Extract Frames…") — every frame, or
    /// sampled every-Nth / N-per-second. No Vision involved.
    case ripFrames
    /// "Reformat and Analyze" — transcode a legacy-codec source
    /// (svq3, qdm2, cinepak, etc.) into modern H.264/AAC mp4 with
    /// conventional ffmpeg filters (bwdif deinterlace, hqdn3d
    /// denoise). Auto-catalogs the output and queues it for analyze.
    /// Rick 2026-06-14: lets the analyzer reach files AVFoundation
    /// can't decode (Apple deprecated svq3/qdm2/etc. in macOS 10.15).
    case reformat
    /// "Analyze This File" — runs the orchestrator's VLM + Whisper
    /// pipeline on a single record. Rick 2026-06-14: Media File
    /// Operations window owns per-file operations; the Analyze
    /// Dashboard owns batch volume-wide operations. Watching one
    /// file's analyze tick along belongs here.
    case analyze
    /// "Transcode" — two-preset faithful conversion to ProRes 422 HQ
    /// (Editing) or HEVC 10-bit (Archival). Rick 2026-06-14 (Pass C):
    /// produces FCP-editable copies and archive-grade copies without
    /// leaving VideoScan. Unlike Reformat, NO deinterlace/denoise and
    /// NO auto-queue Analyze.
    case transcode
    /// "Clean Up Video" — applies a named CleanupRecipe (v1: VHS Quick
    /// Clean single-pass ffmpeg filtergraph) and writes
    /// `<stem>_cleaned.mov` (ProRes LT, audio copied) BESIDE the
    /// original, which is never modified. Rick 2026-07-07.
    case cleanup

    /// Badge text — rendered in small caps by the row view.
    /// `.extract` says "Faces" (not "Extract") since the verb split:
    /// with two extract-style rows in the window, the badge is what
    /// tells them apart at a glance.
    var badgeText: String {
        switch self {
        case .combine: return "Combine"
        case .compare: return "Compare"
        case .extract: return "Faces"
        case .ripFrames: return "Frames"
        case .reformat: return "Reformat"
        case .analyze: return "Analyze"
        case .transcode: return "Transcode"
        case .cleanup: return "Clean Up"
        }
    }
}

// MARK: - State

/// Lifecycle of one operation job.
/// (≈ a C++ tagged union / std::variant — `finished` and `failed`
/// carry a payload string.)
enum MediaFileOperationState: Equatable {
    case running
    /// Cancel was requested; the job's task is still unwinding
    /// (ffmpeg child being terminated, hash loop draining).
    case cancelling
    /// Done — `summary` is the one-line result ("Exact duplicates").
    case finished(summary: String)
    case failed(message: String)
    case cancelled

    /// True while the job still owns live work (running or unwinding).
    var isActive: Bool {
        switch self {
        case .running, .cancelling: return true
        case .finished, .failed, .cancelled: return false
        }
    }
}

// MARK: - Duration clock (pure)

/// PURE duration math for the operations window's row clock — no I/O
/// and no `Date()` of its own (callers inject `now`), so tests can
/// evaluate it at any simulated wall-clock time.
///
/// Semantics (regression fix 2026-07-07):
///   - active job   → live elapsed, `now − startedAt` (keeps ticking)
///   - terminal job → frozen run duration, `finishedAt − startedAt`
/// A terminal job missing its stamp (shouldn't happen — conformers
/// stamp at the transition) falls back to `now`, i.e. best effort.
enum MediaFileOperationClock {

    static func duration(state: MediaFileOperationState,
                         startedAt: Date,
                         finishedAt: Date?,
                         at now: Date) -> TimeInterval {
        if state.isActive {
            return max(0, now.timeIntervalSince(startedAt))
        }
        return max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
    }

    /// Formatted duration for a row: "5s" / "5m 12s" / "1h 5m" — same
    /// shape as the combine section's formatter so the two sections in
    /// the operations window read alike.
    static func text(state: MediaFileOperationState,
                     startedAt: Date,
                     finishedAt: Date?,
                     at now: Date) -> String {
        format(duration(state: state, startedAt: startedAt,
                        finishedAt: finishedAt, at: now))
    }

    /// Convenience for the row view — pulls the three fields off the
    /// job existential.
    @MainActor
    static func text(for job: any MediaFileOperationJob, at now: Date) -> String {
        text(state: job.state, startedAt: job.startedAt,
             finishedAt: job.finishedAt, at: now)
    }

    static func format(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

// MARK: - Job protocol

/// One row in the Media File Operations window. Conformers are
/// observable classes; the row view subscribes to `objectWillChange`
/// so live progress re-renders.
///
/// The `where` clauses pin the associated types so the window can hold
/// heterogeneous jobs as `any MediaFileOperationJob` and still call
/// `objectWillChange` / key by `id` on the existential.
/// (≈ C++: an abstract base class with a change-notification signal,
/// rather than a template.)
@MainActor
protocol MediaFileOperationJob: AnyObject, ObservableObject, Identifiable
where ObjectWillChangePublisher == ObservableObjectPublisher, ID == UUID {
    var id: UUID { get }
    var kind: MediaFileOperationKind { get }
    /// e.g. "IMG_0123.mov vs tape7.mxf"
    var title: String { get }
    /// Live status line ("Reading both files byte-by-byte…").
    var subtitle: String { get }
    /// 0…1 overall progress; ignored while `isIndeterminate`.
    var fraction: Double { get }
    var isIndeterminate: Bool { get }
    var state: MediaFileOperationState { get }
    var startedAt: Date { get }
    /// When the job reached a terminal state (finished / failed /
    /// cancelled); nil while active. Conformers stamp it exactly once
    /// at the terminal transition. The window uses it to FREEZE the
    /// row clock (regression 2026-07-07: the clock kept ticking after
    /// completion, so a 5-minute job read "45 min" when glanced at 40
    /// minutes later). Deliberately a hard requirement with no default
    /// — the compiler forces every future verb to carry the stamp.
    var finishedAt: Date? { get }
    func cancel()

    // Optional pause capability — defaulted off below.
    var canPause: Bool { get }
    var isPaused: Bool { get }
    func pause()
    func resume()
}

/// Pause is opt-in; most operations can't pause mid-ffmpeg.
extension MediaFileOperationJob {
    var canPause: Bool { false }
    var isPaused: Bool { false }
    func pause() {}
    func resume() {}
}

// MARK: - Per-volume gate policy (pure)

/// How many concurrent compare-style heavy reads a volume tolerates.
/// Mirrors the spirit of `ThumbnailPrecachePlanner.concurrencyBound`
/// (HDD=1, SSD/internal unrestricted), with unclassified volumes
/// treated as allowing 2.
enum MediaVolumeGatePolicy {

    /// Slot count for heavy sequential reads on one volume root.
    /// `nil` means unrestricted (no gate is created at all).
    static func compareSlots(mediaTech: VolumeMediaTech,
                             isInternalPath: Bool) -> Int? {
        if isInternalPath { return nil }
        switch mediaTech {
        case .ssd:
            return nil
        case .hdd:
            // One sequential reader at a time — two compares seeking
            // against the same spinning disk thrash it to a crawl.
            return 1
        case .network, .cloud:
            // Gentle on shared links: parallel multi-GB reads over SMB
            // compete with scans and Finder.
            return 2
        default:
            // unknown / RAID variants — unclassified allows 2.
            return 2
        }
    }

    /// "/Volumes/MyBook/sub/file.mov" → "/Volumes/MyBook";
    /// anything not under /Volumes (internal disk) → "/".
    static func volumeRoot(forPath path: String) -> String {
        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/", maxSplits: 3)
            if parts.count >= 2 { return "/Volumes/" + String(parts[1]) }
        }
        return "/"
    }
}

// MARK: - Volume gate (shared by all job types)

/// One volume gate a job must hold while it reads. `root` is the
/// dedupe/sort key; `label` is the friendly volume name for the
/// "Waiting for…" subtitle. Built per-job by
/// `MediaFileOperationsCenter.gatePlan` — the shared `semaphore` per
/// volume root is what serializes HDD reads across jobs.
///
/// Phase 2: hoisted out of PairCompareJob (where phase 1 nested it) so
/// ExtractFramesJob and future verbs share the same type.
struct MediaVolumeGate {
    let root: String
    let label: String
    let semaphore: AsyncSemaphore
}

// MARK: - Center (app-level registry)

/// Owns every new-style operation job, newest-first. Created once in
/// `VideoScanApp` and injected via `environmentObject` so the catalog
/// context menu, the operations window, and the quit guard all see the
/// same instance.
@MainActor
final class MediaFileOperationsCenter: ObservableObject {

    /// All jobs, newest-first. Finished jobs linger (capped, see
    /// `finishedCap`) so Rick can read verdicts later.
    @Published private(set) var jobs: [any MediaFileOperationJob] = []

    /// Keep at most this many non-active jobs around.
    static let finishedCap = 50

    /// Maps a file path to the user's media-tech classification for its
    /// volume (from the scan targets). Wired up by VideoScanApp at
    /// launch; nil / no match ⇒ `.unknown` (gate allows 2).
    var mediaTechForPath: ((String) -> VolumeMediaTech)?

    /// One gate per volume root, shared by every job touching that
    /// volume — that sharing is what serializes HDD reads.
    private var volumeGates: [String: AsyncSemaphore] = [:]

    /// Re-publish each job's changes as our own so list-level UI
    /// (header counts) stays fresh. Keyed by job id for cleanup.
    private var jobForwarders: [UUID: AnyCancellable] = [:]

    var runningCount: Int {
        jobs.filter { $0.state.isActive }.count
    }

    // MARK: List management

    /// Insert newest-first and start forwarding its change events.
    /// Internal (not private) so tests can drive the list directly.
    ///
    /// Forwarder is THROTTLED to 4 Hz (Rick 2026-06-15). Each running
    /// job publishes `fractionValue` etc. on every ffmpeg progress line
    /// (~4-10 Hz per job) plus on every Whisper/VLM log line, and the
    /// unthrottled forwarder re-broadcast all of it through this
    /// Center's `objectWillChange`. With 3-4 active jobs the Catalog
    /// (which observes the Center via `@EnvironmentObject fileOpsCenter`
    /// in CatalogHelpers.swift) was re-rendering 12-40× per second,
    /// starving NSTableView's main-thread mouse hit-testing and making
    /// row selection by mouse glitch during MFO load. Arrow-key
    /// navigation stayed smooth because it bypasses SwiftUI re-eval.
    /// 250 ms / 4 Hz is faster than the eye can resolve on a progress
    /// bar and is still snappy for state transitions. The MFO window's
    /// per-job rows subscribe to the job directly, so their progress
    /// bars stay smooth — they aren't affected by this throttle.
    func add(_ job: any MediaFileOperationJob) {
        jobs.insert(job, at: 0)
        jobForwarders[job.id] = job.objectWillChange
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        trimFinished()
    }

    /// Drop every non-active job (the "Clear Finished" button).
    func clearFinished() {
        let removed = jobs.filter { !$0.state.isActive }
        guard !removed.isEmpty else { return }
        jobs.removeAll { !$0.state.isActive }
        for job in removed { jobForwarders[job.id] = nil }
        fileOpsLog.info("cleared \(removed.count) finished operation(s)")
    }

    /// Ask every live job to stop. Used by the quit guard so ffmpeg
    /// children die before the process exits.
    func cancelAll() {
        let active = jobs.filter { $0.state.isActive }
        guard !active.isEmpty else { return }
        fileOpsLog.info("cancelAll: stopping \(active.count) running operation(s)")
        for job in active { job.cancel() }
    }

    /// Enforce `finishedCap`: keep every active job, and the newest
    /// `finishedCap` non-active ones (list is newest-first, so a single
    /// forward pass keeps the right ones).
    private func trimFinished() {
        var finishedKept = 0
        var keep: [any MediaFileOperationJob] = []
        keep.reserveCapacity(jobs.count)
        for job in jobs {
            if job.state.isActive {
                keep.append(job)
            } else if finishedKept < Self.finishedCap {
                finishedKept += 1
                keep.append(job)
            } else {
                jobForwarders[job.id] = nil
            }
        }
        if keep.count != jobs.count { jobs = keep }
    }

    // MARK: Starting operations

    /// Kick off a quick two-file check. The job owns its run Task; the
    /// caller just opens the operations window to watch it.
    @discardableResult
    func startCompare(recordA: VideoRecord, recordB: VideoRecord) -> PairCompareJob {
        let gates = gatePlan(forPaths: [recordA.fullPath, recordB.fullPath])
        let job = PairCompareJob(recordA: recordA, recordB: recordB, gates: gates)
        add(job)
        job.start()
        fileOpsLog.info("compare started: \(recordA.filename, privacy: .public) vs \(recordB.filename, privacy: .public) (gates: \(gates.count))")
        return job
    }

    /// Kick off a best-frames extraction (phase 2). Same ownership
    /// model as compare: the job owns its run Task, so the rip keeps
    /// going when the operations window closes; the caller just opens
    /// the window to watch it. Reads gate on the source file's volume
    /// (a rip is a long sequential decode — same HDD-thrash concern as
    /// compare).
    @discardableResult
    func startExtract(record: VideoRecord, destinationParent: URL) -> ExtractFramesJob {
        let gates = gatePlan(forPaths: [record.fullPath])
        let job = ExtractFramesJob(record: record,
                                   destinationParent: destinationParent,
                                   gates: gates)
        add(job)
        job.start()
        fileOpsLog.info("extract started: \(record.filename, privacy: .public) → \(destinationParent.path, privacy: .public) (gates: \(gates.count))")
        return job
    }

    /// Kick off an ffmpeg-only frame export ("Extract Frames…", verb
    /// split 2026-06-10). Same ownership/gating model as the facial
    /// extract above — one long sequential read of the source file.
    /// `options` carries the sampling choice from RipAllFramesSheet.
    @discardableResult
    func startRipAllFrames(record: VideoRecord,
                           destinationParent: URL,
                           options: AllFramesRipper.Options) -> RipAllFramesJob {
        let gates = gatePlan(forPaths: [record.fullPath])
        let job = RipAllFramesJob(record: record,
                                  destinationParent: destinationParent,
                                  gates: gates,
                                  options: options)
        add(job)
        job.start()
        fileOpsLog.info("ripFrames started: \(record.filename, privacy: .public) → \(destinationParent.path, privacy: .public) (\(options.sampling.logDescription, privacy: .public), gates: \(gates.count))")
        return job
    }

    /// Kick off "Reformat and Analyze" on a single record — ffmpeg
    /// transcodes the source's legacy-codec stream into modern
    /// H.264/AAC mp4, auto-catalogs the output, and queues it for the
    /// in-app analyzer. Rick 2026-06-14: lets svq3/qdm2/cinepak/etc.
    /// files become analyzable.
    @discardableResult
    func startReformat(record: VideoRecord,
                       model: VideoScanModel,
                       orchestrator: CaptionOrchestrator?) -> ReformatJob {
        let job = ReformatJob(record: record, model: model, orchestrator: orchestrator)
        add(job)
        job.start()
        fileOpsLog.info("reformat started: \(record.filename, privacy: .public) → \(job.outputURL.lastPathComponent, privacy: .public)")
        return job
    }

    /// Kick off a Transcode on a single record. Two-preset faithful
    /// conversion — ProRes 422 HQ for FCP editing or HEVC 10-bit for
    /// long-term archive. Catalogs the new derivative as
    /// workspaceActive with `derivedFrom = record.id`, but does NOT
    /// auto-queue Analyze (the user transcoded for a specific
    /// workflow, not for analysis). Rick 2026-06-14 (Pass C).
    @discardableResult
    func startTranscode(record: VideoRecord,
                        preset: TranscodePreset,
                        outputURL: URL,
                        model: VideoScanModel) -> TranscodeJob {
        let job = TranscodeJob(
            record: record,
            preset: preset,
            outputURL: outputURL,
            model: model
        )
        add(job)
        job.start()
        fileOpsLog.info("transcode started: \(record.filename, privacy: .public) preset=\(preset.rawValue, privacy: .public) → \(job.outputURL.lastPathComponent, privacy: .public)")
        return job
    }

    /// Kick off "Clean Up Video" with a named recipe. The job renders in
    /// scratch (RAM disk when the estimate fits), atomically publishes
    /// `<stem>_cleaned.mov` beside the original (non-clobbering,
    /// re-uniquified at publish time), and catalogs the output with
    /// provenance (derivedFrom + recipe id/version). The original file is
    /// never modified. `plannedOutput` carries the destination the
    /// confirmation sheet displayed (m3); nil computes it fresh.
    /// Rick 2026-07-07.
    @discardableResult
    func startCleanup(record: VideoRecord,
                      recipe: CleanupRecipe,
                      model: VideoScanModel,
                      plannedOutput: URL? = nil) -> CleanupJob {
        let job = CleanupJob(record: record, recipe: recipe, model: model,
                             plannedOutput: plannedOutput)
        add(job)
        job.start()
        fileOpsLog.info("cleanup started: \(record.filename, privacy: .public) recipe=\(recipe.id, privacy: .public) v\(recipe.version) → \(job.outputURL.lastPathComponent, privacy: .public)")
        return job
    }

    /// "Analyze This File" — runs VLM + Whisper on a single record
    /// through the orchestrator (uses fullPath as the prefix so only
    /// this one file enters the candidate set). Rick 2026-06-14:
    /// per-file analyze belongs in the Media File Operations window;
    /// volume-wide batches belong in the Analyze Dashboard.
    @discardableResult
    func startAnalyzeOne(record: VideoRecord,
                         model: VideoScanModel,
                         orchestrator: CaptionOrchestrator,
                         stages: Set<AnalyzeStage> = AnalyzeStage.all) -> AnalyzeJob {
        let job = AnalyzeJob(record: record, model: model,
                             orchestrator: orchestrator, stages: stages)
        add(job)
        job.start()
        fileOpsLog.info("analyze started: \(record.filename, privacy: .public) stages=\(stages.map(\.rawValue).joined(separator: ","), privacy: .public)")
        return job
    }

    /// Build the ordered list of volume gates a job must hold while it
    /// reads. Deduped per volume root; sorted by root so every job
    /// acquires in the same order (≈ the classic lock-ordering rule —
    /// no deadlocks). Volumes whose policy is unrestricted get no gate.
    private func gatePlan(forPaths paths: [String]) -> [MediaVolumeGate] {
        var plan: [MediaVolumeGate] = []
        var seenRoots = Set<String>()
        for path in paths {
            let root = MediaVolumeGatePolicy.volumeRoot(forPath: path)
            guard seenRoots.insert(root).inserted else { continue }
            let isInternal = !path.hasPrefix("/Volumes/")
            let tech = mediaTechForPath?(path) ?? .unknown
            guard let slots = MediaVolumeGatePolicy.compareSlots(
                mediaTech: tech, isInternalPath: isInternal) else { continue }
            let gate: AsyncSemaphore
            if let existing = volumeGates[root] {
                gate = existing
            } else {
                gate = AsyncSemaphore(limit: slots)
                volumeGates[root] = gate
                fileOpsLog.info("volume gate created for \(root, privacy: .public): \(slots) slot(s) (\(tech.rawValue, privacy: .public))")
            }
            plan.append(MediaVolumeGate(
                root: root,
                label: VolumeReachability.displayLabel(forPath: path),
                semaphore: gate))
        }
        return plan.sorted { $0.root < $1.root }
    }
}
