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
    /// "Trim Master…" — cuts static/garbage off the head and tail of an
    /// archival capture with a pure ffmpeg STREAM COPY (no re-encode,
    /// zero quality loss) and writes `<stem>_trimmed.<same ext>` BESIDE
    /// the original, which is never modified. Rick 2026-07-16.
    case trim
    /// "Balance Audio" — fixes one-sided (left/right-only) or mono
    /// audio by duplicating the live channel to both sides; video
    /// stream-copied, `<stem>_balanced.<ext>` beside the original,
    /// which is never modified. GH #116, Rick 2026-07.
    case balanceAudio
    /// "Rebuild Audio Track" — the Verify Audio repair (GH #128):
    /// video stream-copied, audio re-encoded to pcm_s16le in a .mov,
    /// `<stem>_RepairedAudio.mov` beside the original, which is never
    /// modified. Rick 2026-07-24.
    case rebuildAudio
    /// "Verify Audio" — the diagnosis itself as a job (GH #135, Rick
    /// 2026-07-24): the levels pass decodes the whole audio track
    /// (minutes on long tapes), so it runs HERE, never in a modal
    /// sheet over the catalog. Single- and multi-select both dispatch
    /// these; the results sheet presents the already-computed
    /// diagnosis afterwards without re-running anything.
    case verifyAudio
    /// "Find & Tag" — runs a per-person detector recipe (Donna Recipe,
    /// docs/find-and-tag-design.md) over selected records and writes
    /// MACHINE-tier person tags (detected "Donna*" / suspected
    /// "Donna?"); confirmed stays human-only. v1 bridges to the python
    /// recipe engine via ProcessRunner; Swift-native engine to follow
    /// behind the same job. Rick 2026-08-02.
    case findPerson
    /// "Promote to Archive" — verified byte-for-byte copy of one or more
    /// records into the Master Archive tree (spec §5): copy → streamed
    /// sha256 of source and destination → rename into place → manifest
    /// row → linked catalog record. Never a move; never a re-encode.
    /// docs/archive_promotion_workflow.md, Rick 2026-08-15.
    case promote

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
        case .trim: return "Trim"
        case .balanceAudio: return "Balance"
        case .rebuildAudio: return "Rebuild"
        case .verifyAudio: return "Verify"
        case .findPerson: return "Find"
        case .promote: return "Promote"
        }
    }

    /// Lowercase verb used in the videoscan.log START/OUTCOME summary
    /// lines ("trim done: …", "balance audio FAILED: …"). Distinct from
    /// `badgeText` (UI capitalization) and deliberately matching the
    /// wording the pre-existing ad-hoc log lines already used, so
    /// greps over old logs keep working.
    var logVerb: String {
        switch self {
        case .combine: return "combine"
        case .compare: return "compare"
        case .extract: return "extract faces"
        case .ripFrames: return "extract frames"
        case .reformat: return "reformat"
        case .analyze: return "analyze"
        case .transcode: return "transcode"
        case .cleanup: return "cleanup"
        case .trim: return "trim"
        case .balanceAudio: return "balance audio"
        case .rebuildAudio: return "rebuild audio"
        case .verifyAudio: return "verify audio"
        case .findPerson: return "find person"
        case .promote: return "promote"
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

    /// True when the job was REFUSED before doing any work (duplicate
    /// dispatch, safety gate). The terminal state is still `.failed` —
    /// the flag only changes the file-log OUTCOME wording from
    /// "<verb> FAILED:" to "<verb> refused:", so postmortem greps can
    /// tell "the operation broke" from "the guard said no". Defaulted
    /// false below; conformers with refusal paths set it.
    var wasRefused: Bool { get }
}

/// Pause is opt-in; jobs whose work is an ffmpeg child adopt it via
/// JobPauseCoordinator (GH #150). In-process loops (Vision extract) and
/// multi-source engines (compare) stay unpausable for now.
extension MediaFileOperationJob {
    var canPause: Bool { false }
    var isPaused: Bool { false }
    func pause() {}
    func resume() {}
    var wasRefused: Bool { false }
}

/// Shared pause plumbing for ffmpeg-backed jobs (GH #150 — MFO Pause All).
///
/// Owns the ProcessControl handed to every ProcessRunner call the job makes
/// (SIGSTOP/SIGCONT on the live child, pause-between-phases remembered),
/// and keeps the job's current StallMonitor honest: a suspended child emits
/// no progress BY DESIGN, so the watchdog must be stopped on pause or it
/// would read the silence as the 14-hour-hang class and kill the job.
/// StallMonitor.start() resets its tick clock, so resume can't instant-fire.
@MainActor
final class JobPauseCoordinator {
    let control = ProcessControl()
    private(set) var isPaused = false
    private weak var monitor: StallMonitor?

    /// Adopt the current phase's watchdog (call right after monitor.start()).
    /// If the user paused between phases, the fresh monitor is stopped
    /// immediately — its child is born suspended via ProcessControl.attach.
    func register(_ monitor: StallMonitor) {
        self.monitor = monitor
        if isPaused { monitor.stop() }
    }

    /// Returns false when already paused (idempotent for the UI).
    @discardableResult
    func pause() -> Bool {
        guard !isPaused else { return false }
        isPaused = true
        control.suspend()
        monitor?.stop()
        return true
    }

    /// Returns false when not paused.
    @discardableResult
    func resume() -> Bool {
        guard isPaused else { return false }
        isPaused = false
        control.resume()
        monitor?.start()
        return true
    }
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
    /// anything not under /Volumes (internal disk) → "/". Forwards to
    /// VideoScanCore's `previewVolumeRoot` — the preview sweep planner
    /// (Core) needs the same rule, so it lives there as the single source.
    static func volumeRoot(forPath path: String) -> String {
        previewVolumeRoot(forPath: path)
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

// MARK: - Gate-holder board (waiting-row honesty)

/// Who currently holds each volume-gate slot — so a queued job's row
/// can say WHAT it's waiting behind (2026-08-07: a compare waited ~3 h
/// for the LaCie with no clue a paused Verify Audio held the slot;
/// the mystery cost an afternoon). Best-effort UI truth, NOT
/// synchronization: multi-slot volumes overwrite last-writer, and the
/// semaphore stays the only authority on admission.
///
/// codex #292 round: ObservableObject (waiting rows must actually
/// re-render when the holder changes — gated jobs forward
/// `objectWillChange`), and entries are keyed by JOB ID so two jobs
/// with identical display names can't clear each other.
@MainActor
final class VolumeGateBoard: ObservableObject {

    static let shared = VolumeGateBoard()

    struct Holder: Equatable {
        let jobID: UUID
        let name: String
    }

    @Published private(set) var holders: [String: Holder] = [:]

    func claim(root: String, jobID: UUID, name: String) {
        holders[root] = Holder(jobID: jobID, name: name)
    }

    /// Clears only if THIS job still owns the entry — identity is the
    /// job id, never the display string (two "Verify IMG_0795.MOV"
    /// jobs are distinct).
    func clear(root: String, jobID: UUID) {
        if holders[root]?.jobID == jobID { holders[root] = nil }
    }

    /// The waiting-row sentence: names the current holder when known.
    static func describeWait(label: String, root: String) -> String {
        if let holder = shared.holders[root], !holder.name.isEmpty {
            return "Waiting for \(label) — in use by \(holder.name)…"
        }
        return "Waiting for \(label)…"
    }
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

    // MARK: File-log summaries (START / OUTCOME)
    //
    // Every MFO job writes exactly ONE start line and ONE terminal line
    // to `appLog` (~/Library/Logs/VideoScan/videoscan.log) so failures
    // are greppable after the fact — motivating case 2026-07-17: a
    // Balance Audio ffmpeg failure (exit 183) lived only in the MFO
    // window and OSLog; videoscan.log went silent. The START lines are
    // written by the `start…` methods below (they know the per-verb
    // plan clause); the OUTCOME line is written HERE, at the Center's
    // single choke point, by watching each job's change publisher for
    // the terminal transition — no per-job copy-pasted call sites, and
    // derived-state jobs (compare/extract/ripFrames) are covered
    // without touching their internals.
    //
    // Memory: three collections keyed by job UUID, pruned when jobs
    // leave the list — bounded by `finishedCap` + active jobs (≈ 50–60
    // entries, bytes each). Worst case is trivially small.

    /// Unthrottled terminal-transition watchers (the 4 Hz forwarder
    /// above can't be reused — its throttling could sample state
    /// mid-transition, and OUTCOME logging must be exactly-once).
    private var terminalWatchers: [UUID: AnyCancellable] = [:]
    /// Jobs whose OUTCOME line has been written — the exactly-once guard.
    private var terminalLogged: Set<UUID> = []
    /// Coalesces the change-event flood (progress beats arrive 4–10 Hz
    /// per job) down to one pending state check at a time.
    private var terminalCheckScheduled: Set<UUID> = []

    var runningCount: Int {
        jobs.filter { $0.state.isActive }.count
    }

    // MARK: Verify Audio diagnosis cache (GH #135)
    //
    // Completed VerifyAudioJobs park their computed AudioVerifyDiagnosis
    // here, keyed by record id, so "Audio Info…" can present
    // it instantly — no re-probe, and NEVER a re-run of the levels pass
    // (the whole-track decode that motivated moving verify off the
    // sheet). Session-scoped, newest-wins per record.
    //
    // Memory: a diagnosis is a few small value structs (findings +
    // shape + optional per-channel levels) — well under 1 KB each.
    // FIFO-capped at 200 entries ⇒ worst case ~200 KB.

    private var verifyDiagnoses: [UUID: AudioVerifyDiagnosis] = [:]
    private var verifyDiagnosisOrder: [UUID] = []
    static let verifyDiagnosisCap = 200

    /// The most recent completed diagnosis for a record this session,
    /// or nil (never verified this session / evicted by the cap).
    func verifyDiagnosis(forRecordID id: UUID) -> AudioVerifyDiagnosis? {
        verifyDiagnoses[id]
    }

    /// Store (newest-wins) with FIFO eviction at the cap. Internal so
    /// tests can seed the cache directly.
    func storeVerifyDiagnosis(_ diagnosis: AudioVerifyDiagnosis, forRecordID id: UUID) {
        if verifyDiagnoses[id] == nil {
            verifyDiagnosisOrder.append(id)
            if verifyDiagnosisOrder.count > Self.verifyDiagnosisCap {
                let evicted = verifyDiagnosisOrder.removeFirst()
                verifyDiagnoses[evicted] = nil
            }
        }
        verifyDiagnoses[id] = diagnosis
        objectWillChange.send()   // context menus key off cache presence
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
        terminalWatchers[job.id] = job.objectWillChange
            .sink { [weak self, weak job] _ in
                guard let self, let job else { return }
                self.scheduleTerminalCheck(job)
            }
        // A job can arrive already terminal (a refused/parked row) — it
        // will never publish another change, so check once right away.
        scheduleTerminalCheck(job)
        trimFinished()
    }

    /// Drop every non-active job (the "Clear Finished" button).
    func clearFinished() {
        let removed = jobs.filter { !$0.state.isActive }
        guard !removed.isEmpty else { return }
        jobs.removeAll { !$0.state.isActive }
        for job in removed { releaseLogBookkeeping(for: job) }
        fileOpsLog.info("cleared \(removed.count) finished operation(s)")
    }

    /// Ask every live job to stop. Used by the quit guard so ffmpeg
    /// children die before the process exits, and by the window
    /// header's "Cancel All" (Rick 2026-07-31).
    func cancelAll() {
        let active = jobs.filter { $0.state.isActive }
        guard !active.isEmpty else { return }
        fileOpsLog.info("cancelAll: stopping \(active.count) running operation(s)")
        for job in active { job.cancel() }
    }

    /// Pause every live job that supports it (header "Pause All").
    /// Jobs without pause capability keep running — pause is opt-in.
    func pauseAll() {
        let targets = jobs.filter { $0.state.isActive && $0.canPause && !$0.isPaused }
        guard !targets.isEmpty else { return }
        fileOpsLog.info("pauseAll: pausing \(targets.count) operation(s)")
        for job in targets { job.pause() }
    }

    /// Resume every paused job (header "Resume All").
    func resumeAll() {
        let targets = jobs.filter { $0.state.isActive && $0.isPaused }
        guard !targets.isEmpty else { return }
        fileOpsLog.info("resumeAll: resuming \(targets.count) operation(s)")
        for job in targets { job.resume() }
    }

    /// True when at least one live job could be paused right now —
    /// drives the header's adaptive Pause All / Resume All button.
    var hasPausableRunning: Bool {
        jobs.contains { $0.state.isActive && $0.canPause && !$0.isPaused }
    }

    /// True when at least one live job is currently paused.
    var hasPausedJobs: Bool {
        jobs.contains { $0.state.isActive && $0.isPaused }
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
                releaseLogBookkeeping(for: job)
            }
        }
        if keep.count != jobs.count { jobs = keep }
    }

    // MARK: File-log summary plumbing

    /// Drop a departing job's subscriptions and log bookkeeping — but
    /// first make sure its OUTCOME line was written (a job can be
    /// removed in the same main-actor turn as its terminal transition,
    /// before the scheduled async check ran).
    private func releaseLogBookkeeping(for job: any MediaFileOperationJob) {
        logTerminalIfNeeded(job)
        jobForwarders[job.id] = nil
        terminalWatchers[job.id] = nil
        // Prune the exactly-once marker ONLY when no deferred check is
        // still in flight — a pending check re-reading a pruned id
        // would double-write the OUTCOME line. (The unpruned entry in
        // that rare overlap is 16 bytes, reclaimed at app exit.)
        if !terminalCheckScheduled.contains(job.id) {
            terminalLogged.remove(job.id)
        }
    }

    /// Coalesced deferred state check. `objectWillChange` fires BEFORE
    /// the mutation lands (it's a *will*-change signal — ≈ observing a
    /// setter's entry, not its exit), so the read is hopped to the next
    /// main-actor turn, by which point the new state has settled.
    private func scheduleTerminalCheck(_ job: any MediaFileOperationJob) {
        let id = job.id
        guard !terminalLogged.contains(id),
              terminalCheckScheduled.insert(id).inserted else { return }
        Task { @MainActor [weak self, weak job] in
            guard let self else { return }
            self.terminalCheckScheduled.remove(id)
            guard let job else { return }
            self.logTerminalIfNeeded(job)
        }
    }

    /// Write the one-and-only OUTCOME line if `job` has reached a
    /// terminal state. Safe to call repeatedly — `terminalLogged` makes
    /// it idempotent.
    private func logTerminalIfNeeded(_ job: any MediaFileOperationJob) {
        guard !job.state.isActive, !terminalLogged.contains(job.id) else { return }
        terminalLogged.insert(job.id)
        terminalWatchers[job.id] = nil
        if let line = Self.terminalSummaryLine(verb: job.kind.logVerb,
                                              title: job.title,
                                              state: job.state,
                                              wasRefused: job.wasRefused) {
            appLog.write(line)
        }
    }

    /// START line — "<verb>: <title> — <one-clause plan>". Pure; the
    /// `start…` methods below supply the per-verb plan clause.
    /// (`nonisolated` ≈ a free function that only happens to live in
    /// the class's namespace — no shared state, callable off-main.)
    nonisolated static func startSummaryLine(verb: String, title: String,
                                             plan: String) -> String {
        "\(verb): \(title) — \(plan)"
    }

    /// OUTCOME line for a terminal state; nil while the job is active.
    /// Pure and static so tests can pin the exact format per state.
    /// The failed/refused message is the SAME user-facing reason string
    /// the MFO window row shows — no separate wording to drift.
    nonisolated static func terminalSummaryLine(verb: String, title: String,
                                                state: MediaFileOperationState,
                                                wasRefused: Bool) -> String? {
        switch state {
        case .running, .cancelling:
            return nil
        case .finished(let summary):
            return "\(verb) done: \(title) — \(summary)"
        case .failed(let message):
            return wasRefused
                ? "\(verb) refused: \(title) — \(message)"
                : "\(verb) FAILED: \(title) — \(message)"
        case .cancelled:
            return "\(verb) cancelled: \(title)"
        }
    }

    /// Instance convenience for the `start…` methods.
    private func logStart(_ job: any MediaFileOperationJob, plan: String) {
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb,
                                           title: job.title, plan: plan))
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
        logStart(job, plan: "duplicate check")
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
        logStart(job, plan: "best portrait frames → \(destinationParent.lastPathComponent)/")
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
        logStart(job, plan: "\(options.sampling.logDescription) → \(destinationParent.lastPathComponent)/")
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
        logStart(job, plan: "legacy codec → H.264/AAC \(job.outputURL.lastPathComponent)")
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
        logStart(job, plan: "\(preset.rawValue) → \(job.outputURL.lastPathComponent)")
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
        logStart(job, plan: "\(recipe.displayName) → \(job.outputURL.lastPathComponent)")
        return job
    }

    /// Kick off "Trim Master…" on a single record — a stream-copy trim
    /// (never a re-encode) that publishes `<stem>_trimmed.<same ext>`
    /// beside the original and catalogs it with provenance. The original
    /// file and its catalog record are never modified beyond a journey
    /// note. `plannedOutput` carries the destination the trim sheet
    /// displayed; nil computes it fresh. `probedIntra` carries the
    /// sheet's packet-flag keyframe probe verdict (nil = probe not run /
    /// undecidable) so the job's summary wording and verification
    /// tolerance honor what the probe learned about the ACTUAL file,
    /// not just the codec name (QA MAJOR 1, 2026-07-17). Rick 2026-07-16.
    @discardableResult
    func startTrim(record: VideoRecord,
                   range: TrimRange,
                   model: VideoScanModel,
                   plannedOutput: URL? = nil,
                   probedIntra: Bool? = nil) -> TrimJob {
        let job = TrimJob(record: record, range: range, model: model,
                          plannedOutput: plannedOutput,
                          probedIntra: probedIntra)
        add(job)
        // Same-record dedupe guard (QA MAJOR 2, 2026-07-17). The context
        // menu greys out "Trim Master…" while a trim runs, but the Center
        // is the last line of defense for every caller: two trims of one
        // record share the `.vs-partial` path, so the second job's
        // stale-partial cleanup would unlink the first job's in-flight
        // output. Refuse loudly — the parked row carries the reason.
        let duplicate = jobs.contains { other in
            guard other.id != job.id, other.state.isActive,
                  let t = other as? TrimJob else { return false }
            return t.record.id == record.id
        }
        if duplicate {
            fileOpsLog.warning("trim REFUSED (already running for this record): \(record.filename, privacy: .public)")
            // No START line for a refused job — nothing started; the
            // terminal watcher writes the one "trim refused:" line.
            job.refuseToStart(reason: "A trim of \(record.filename) is already running — wait for it to finish (or cancel it) before starting another. Nothing was started.")
            return job
        }
        job.start()
        fileOpsLog.info("trim started: \(record.filename, privacy: .public) [\(TrimTimecode.format(range.inSeconds), privacy: .public) → \(TrimTimecode.format(range.outSeconds), privacy: .public)] → \(job.outputURL.lastPathComponent, privacy: .public)")
        logStart(job, plan: "[\(TrimTimecode.format(range.inSeconds)) → \(TrimTimecode.format(range.outSeconds))] stream copy → \(job.outputURL.lastPathComponent)")
        return job
    }

    /// Kick off "Balance Audio" on a single record. The caller supplies
    /// an ALREADY-COMPUTED analysis — since the GH #137 consolidation
    /// the analyzer only ever runs inside a VerifyAudioJob, and the
    /// Verify results sheet's Balance offer forwards its diagnosis's
    /// analysis here (use the `fromDiagnosis` overload below). The job
    /// re-verifies the output after the fix. Returns nil — REFUSING the
    /// dispatch — when a balance job is already active for this same
    /// record (the MFO-layer duplicate guard: two concurrent jobs
    /// against one input would race on the same planned output name).
    /// GH #116.
    @discardableResult
    func startBalanceAudio(record: VideoRecord,
                           analysis: AudioBalanceAnalysis,
                           model: VideoScanModel,
                           plannedOutput: URL? = nil) -> BalanceAudioJob? {
        let duplicate = jobs.contains { job in
            guard job.state.isActive, let b = job as? BalanceAudioJob else { return false }
            return b.record.id == record.id
        }
        guard !duplicate else {
            fileOpsLog.notice("balanceAudio REFUSED duplicate dispatch: \(record.filename, privacy: .public) already has an active balance job")
            // No job row exists for this refusal (dispatch returned nil),
            // so the terminal watcher can't write it — log it here.
            appLog.write("balance audio refused: \(record.filename) — a balance job for this file is already running; nothing was started")
            return nil
        }
        let job = BalanceAudioJob(record: record, analysis: analysis,
                                  model: model, plannedOutput: plannedOutput)
        add(job)
        job.start()
        fileOpsLog.info("balanceAudio started: \(record.filename, privacy: .public) class=\(analysis.classification.rawValue, privacy: .public) → \(job.outputURL.lastPathComponent, privacy: .public)")
        logStart(job, plan: "\(analysis.classification.rawValue) → \(job.outputURL.lastPathComponent)")
        return job
    }

    /// Balance Audio straight from a completed Verify diagnosis — the
    /// GH #137 consolidation entry point (the Verify results sheet's
    /// "Balance Audio" button). The diagnosis already CONTAINS the
    /// balance analysis, so this can never trigger a fresh decode;
    /// a diagnosis without one (reference movie, no-audio, undecodable
    /// track) returns nil and starts nothing — the sheet never shows
    /// the button in those cases, this guard is the model-layer twin.
    @discardableResult
    func startBalanceAudio(record: VideoRecord,
                           fromDiagnosis diagnosis: AudioVerifyDiagnosis,
                           model: VideoScanModel,
                           plannedOutput: URL? = nil) -> BalanceAudioJob? {
        guard let analysis = diagnosis.balanceAnalysis else {
            fileOpsLog.notice("balanceAudio dispatch skipped: \(record.filename, privacy: .public) — diagnosis carries no balance analysis")
            return nil
        }
        return startBalanceAudio(record: record, analysis: analysis,
                                 model: model, plannedOutput: plannedOutput)
    }

    /// Kick off "Rebuild Audio Track" — the Verify Audio repair
    /// (GH #128): video stream-copied, audio re-encoded to pcm_s16le in
    /// a .mov beside the original. The sheet already ran the diagnosis
    /// (verify-then-repair); `reason` is the diagnosed cause, carried
    /// into the derived record's File Journey stamp. Returns nil —
    /// REFUSING the dispatch — when a rebuild is already active for
    /// this same record (two jobs against one input would race on the
    /// same planned output name).
    @discardableResult
    func startRebuildAudio(record: VideoRecord,
                           reason: String,
                           shape: AudioVerifyShape,
                           model: VideoScanModel,
                           plannedOutput: URL? = nil) -> RebuildAudioJob? {
        let duplicate = jobs.contains { job in
            guard job.state.isActive, let r = job as? RebuildAudioJob else { return false }
            return r.record.id == record.id
        }
        guard !duplicate else {
            fileOpsLog.notice("rebuildAudio REFUSED duplicate dispatch: \(record.filename, privacy: .public) already has an active rebuild job")
            appLog.write("rebuild audio refused: \(record.filename) — a rebuild job for this file is already running; nothing was started")
            return nil
        }
        // Per-disk pacing (GH #132): the rebuild is a long sequential
        // read+write on the source's volume — it takes the same gates
        // compare/extract do, so a 25-job batch on one HDD renders one
        // at a time instead of thrashing the disk.
        let job = RebuildAudioJob(record: record, reason: reason,
                                  shape: shape, model: model,
                                  plannedOutput: plannedOutput,
                                  gates: gatePlan(forPaths: [record.fullPath]))
        add(job)
        job.start()
        fileOpsLog.info("rebuildAudio started: \(record.filename, privacy: .public) (\(reason, privacy: .public)) → \(job.outputURL.lastPathComponent, privacy: .public)")
        logStart(job, plan: "\(reason) → \(job.outputURL.lastPathComponent)")
        return job
    }

    /// Kick off "Verify Audio" as an MFO job (GH #135 — the levels pass
    /// decodes the whole audio track, so it must never block the UI in
    /// a sheet). Persists the verdict on completion, parks the computed
    /// diagnosis in the cache for "Verification Results…", and — when
    /// `autoRepair` is set (the batch "Repair Damaged Audio" path) —
    /// chains straight into `startRebuildAudio` for an unsupported-codec
    /// finding (the Center's duplicate guard protects the chain).
    /// Returns nil — REFUSING the dispatch — when a verify job is
    /// already active for this same record.
    ///
    /// `diagnoseOverride` is a TEST SEAM only (the VerifyAudioProbe
    /// override convention) — every production call site passes nil.
    @discardableResult
    func startVerifyAudio(record: VideoRecord,
                          model: VideoScanModel,
                          autoRepair: Bool = false,
                          diagnoseOverride: (@Sendable (String) async throws -> AudioVerifyDiagnosis)? = nil) -> VerifyAudioJob? {
        let duplicate = jobs.contains { job in
            guard job.state.isActive, let v = job as? VerifyAudioJob else { return false }
            return v.record.id == record.id
        }
        guard !duplicate else {
            fileOpsLog.notice("verifyAudio REFUSED duplicate dispatch: \(record.filename, privacy: .public) already has an active verify job")
            appLog.write("verify audio refused: \(record.filename) — a verify job for this file is already running; nothing was started")
            return nil
        }
        let job = VerifyAudioJob(record: record,
                                 model: model,
                                 autoRepair: autoRepair,
                                 gates: gatePlan(forPaths: [record.fullPath]),
                                 diagnoseOverride: diagnoseOverride)
        job.onDiagnosis = { [weak self, weak model] job, diagnosis in
            guard let self else { return }
            self.storeVerifyDiagnosis(diagnosis, forRecordID: job.record.id)
            guard job.autoRepair, let model else { return }
            // One repair verb per finding kind: the rebuild covers the
            // unsupported/undecodable-codec class only. Other findings
            // (reference movie, wrong-audio) have no automatic repair.
            if let finding = diagnosis.findings.first(where: {
                if case .unsupportedCodec = $0 { return true }
                return false
            }) {
                self.startRebuildAudio(record: job.record,
                                       reason: VerifyAudioRules.noteFragment(for: finding),
                                       shape: diagnosis.shape,
                                       model: model)
            }
        }
        add(job)
        job.start()
        fileOpsLog.info("verifyAudio started: \(record.filename, privacy: .public) (autoRepair=\(autoRepair))")
        logStart(job, plan: autoRepair ? "diagnose + repair if damaged" : "diagnose the audio track")
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
        logStart(job, plan: "stages \(stages.map(\.rawValue).sorted().joined(separator: "+"))")
        return job
    }

    /// Build the ordered list of volume gates a job must hold while it
    /// reads. Deduped per volume root; sorted by root so every job
    /// acquires in the same order (≈ the classic lock-ordering rule —
    /// no deadlocks). Volumes whose policy is unrestricted get no gate.
    /// Internal (was private) so verb extensions in sibling files
    /// (MediaFileOperations+Promote.swift) can build the same plan.
    func gatePlan(forPaths paths: [String]) -> [MediaVolumeGate] {
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
