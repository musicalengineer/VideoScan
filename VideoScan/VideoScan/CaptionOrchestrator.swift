import Foundation
import AVFoundation
import Combine
import os

// MARK: - CaptionOrchestrator
//
// Stage 6b. Owns the per-target captioning batch: discover the files in
// the catalog that need captions, drive `CaptionRunner.caption(...)`
// once per file, write back results immediately at each file boundary,
// surface progress + ETA + current-file UI state, and honor cancel.
//
// Shape mirrors PersonFinderModel's per-job state machine (ScanJobStatus
// + runScan / processOneVideo) but at a lower complexity: there is no
// reference-photo loading, no per-frame face matching, no clip
// extraction. The orchestrator is mostly plumbing around the engine.
//
// Critical design choice: session-scoped model container, now KEPT
// ALIVE across batches with an idle timeout (perf item 3, 2026-07-14).
//
// History. S6a's MLXVLMCaptionRunner loaded the container once per
// caption() CALL (~30s per file). S6b scoped the container to the
// batch: one runner actor per batch, dropped at settle. That still
// paid a fresh ~30s model load on EVERY batch transition — N
// multi-selected single-file Analyze jobs = N×30s, and every
// queued-volume hand-off ate another load. 2026-07-14: Rick approved
// reversing the batch-scoped decision (his standing RAM directive —
// spend the 64 GB freely when it makes the app meaningfully faster).
// The orchestrator now caches the runner actor across batch settles
// (`cachedRunner`): every runner-creation site goes through
// `acquireRunner()` (cached-or-factory), and a 10-minute idle timer —
// armed on settle, cancelled on the next batch start — releases the
// runner (and with it the ~3 GB container) when no work follows.
//
// SAFETY-CRITICAL: the shutdown path. `beginShutdown()` /
// `drainForShutdown()` drop the cached runner IMMEDIATELY, even
// mid-idle-window, and the `isShuttingDown` latch keeps any late
// start (or a racing idle timer) from resurrecting it. Fresh VLM
// work dispatching GPU during app teardown is exactly the
// mid-inference exit crash (VideoScan-2026-06-11-232946.ips). The
// process-level MLX teardown — GPU-stream synchronize + the `_exit`
// backstop — lives in AppDelegate / MLXShutdown.swift, unchanged:
// this cache only adds "one more strong reference to release before
// quit", which the shutdown hooks below handle.
//
// `cancel()` is NOT shutdown: a cancelled batch keeps the cached
// runner for the next batch. That preserves the pre-keep-alive
// teardown semantics — cancel never performed any explicit MLX/GPU
// teardown; the batch-scoped runner was simply released when the
// batch task settled, and the whisper-worker kill in cancel() is
// about the Python subprocess, not MLX.
//
// Worst-case memory footprint: one ModelContainer (~3 GB for the
// 4-bit Qwen2.5-VL-3B weights) + transient CIImage per frame (decoded
// video frame, typically <50 MB) + KV cache (<100 MB). Total ceiling
// ~3.5 GB — unchanged, but now held for up to `runnerIdleTimeout`
// (10 min) past the last batch settle instead of being released at
// batch end. Bounded: exactly ONE cached runner, the idle timer is
// the release valve, and shutdown drops it unconditionally. No
// per-file accumulation — captions are flushed to the catalog and
// dropped from the orchestrator's working set at each boundary.

// `internal` (no access keyword) rather than `private`: the orchestrator's
// methods now live across CaptionOrchestrator+Lifecycle / +Dossier /
// +Captioning / +Activity, and Swift `private` is file-scoped — a method in
// another file can't reach a `private` file-level logger. (refactor 2026-06-24)
let captionOrchLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "caption-orchestrator")
let shutdownLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "shutdown")


// MARK: - Orchestrator

/// `@MainActor` so all status mutations cross the UI boundary safely
/// without explicit hops. The captioning work itself runs in a detached
/// Task — only the status writebacks return to the main actor.
@MainActor
final class CaptionOrchestrator: ObservableObject {

    // MARK: Published state

    /// Current batch status. Drives the progress sheet visibility.
    @Published var currentStatus: CaptionJobStatus = .idle

    /// Target the running batch is operating on. nil when idle.
    @Published var currentTarget: CatalogScanTarget?

    /// Volume-prefix the active per-volume batch is processing
    /// (`startAnalyzing(volumePrefix:)`). nil for legacy
    /// catalog-wide batches and when idle. The dashboard reads this
    /// to render which volume row shows the "analyzing" status dot.
    /// Rick 2026-06-13: dossier is now driven per-volume from the
    /// dashboard's volume row.
    @Published var currentVolumePrefix: String?

    /// True while the user has the pipeline paused via the volume
    /// row's Pause button. The batch loop checks before dispatching
    /// each next file and awaits until cleared. The currently
    /// in-flight VLM/Whisper task is NOT signaled — it runs to
    /// completion. So Pause prevents NEW work; in-flight work
    /// drains.
    @Published var paused: Bool = false

    /// Number of frames per file to caption. Default 3 matches S6a's
    /// fixture pattern. Tunable later by the UI; constant for now.
    let framesPerFile: Int

    /// Force-recaption even when the record's `sceneCaptionModel`
    /// matches the current engine's `modelID`. Idempotent skip is the
    /// default; this is the "re-caption all" escape hatch the UI may
    /// pass for the future "Re-caption" action.
    var force: Bool = false

    // MARK: Internal state

    /// Active captioning task. Holding the reference lets cancel()
    /// actually cancel; `Task.checkCancellation()` inside the loop
    /// flips the runner out promptly.
    ///
    /// `internal` (not `private`) so the lifecycle + dossier entry
    /// points — now in CaptionOrchestrator+Lifecycle / +Dossier — can
    /// assign and await it. Swift `private` is file-scoped, and a
    /// cross-file `extension` can't reach a `private` member.
    var activeTask: Task<Void, Never>?

    /// In-flight Whisper task (pipelined path only — at most one
    /// outstanding by design). Lifted from a loop-local in
    /// `runDossierBatchPipelined` to instance state so `skipLane(_:)`
    /// can cancel it from the UI when the user clicks Skip on a stuck
    /// transcription. Always set together with `pendingWhisperLaneID`.
    ///
    /// `internal` (not `private`): set by `runDossierBatch`
    /// (CaptionOrchestrator+Dossier) and read/cancelled by `skipLane`
    /// (CaptionOrchestrator+Activity) — two separate files.
    var pendingWhisperTask: Task<Void, Never>?
    var pendingWhisperLaneID: UUID?

    /// The active batch's persistent Whisper worker, when the batch's
    /// transcriber is a `WhisperWorkerTranscriber` (perf item 1,
    /// 2026-07-14). Registered by the dossier batch loops at start and
    /// cleared on settle so `cancel()` / `drainForShutdown()` can kill
    /// the worker subprocess IMMEDIATELY — task cancellation alone only
    /// reaches the worker when the in-flight pipe await resumes, which
    /// a hung transcription would postpone indefinitely.
    ///
    /// `internal` (not `private`): set by the batch loops
    /// (CaptionOrchestrator+Dossier) and read by cancel / drain
    /// (CaptionOrchestrator+Lifecycle) — separate files.
    var activeWhisperWorker: WhisperWorkerTranscriber?

    /// Lane IDs the user explicitly skipped (right-click → Skip). The
    /// pipelined loop checks this set BEFORE dispatching Whisper (so a
    /// skip during the VLM phase short-circuits Whisper) and the
    /// Whisper task's CancellationError branch checks it to use the
    /// "user skipped" note instead of "transcript failed". Cleared at
    /// the start of every batch — skips don't persist across runs.
    ///
    /// `internal` (not `private`): mutated by the dossier loops
    /// (CaptionOrchestrator+Dossier) and by resetLiveCounts / skipLane
    /// (CaptionOrchestrator+Activity).
    var userSkippedLaneIDs: Set<UUID> = []

    /// Injectable engine. Default builds an MLXVLMCaptionRunner. Tests
    /// can swap in a stub runner that returns deterministic captions
    /// without touching MLX. Batch entry points call `acquireRunner()`
    /// (below) rather than this factory directly, so the keep-alive
    /// cache sits in front of whatever the factory builds — injection
    /// unchanged, existing tests unaffected.
    var runnerFactory: () -> CaptionRunner

    // MARK: - VLM runner keep-alive (perf item 3, 2026-07-14)

    /// The runner actor kept alive across batch settles. See the
    /// design comment at the top of this file. Nil when never used,
    /// after the idle window expires, or once shutdown begins.
    /// `internal` so the +Lifecycle/+Dossier entry points (and tests)
    /// can reach it; mutate ONLY via acquireRunner /
    /// armRunnerIdleTimer / dropCachedRunnerForShutdown.
    var cachedRunner: CaptionRunner?

    /// Pending idle-release timer. Armed on batch settle, cancelled on
    /// the next batch start and on shutdown. (`Task` handle ≈ C++
    /// std::jthread with a stop_token — cancel() requests the stop,
    /// the sleeping task observes it.)
    var runnerIdleTimer: Task<Void, Never>?

    /// Idle window before the cached runner — and the ~3 GB model
    /// container it owns — is released. `var` purely as a test seam
    /// (tests shrink it to milliseconds); production never reassigns.
    var runnerIdleTimeout: TimeInterval = 600  // 10 minutes

    /// Get the batch's runner: reuse the cached actor when present,
    /// otherwise build one via `runnerFactory` and cache it. Always
    /// cancels a pending idle timer first — a starting batch must
    /// never have the container released out from under it.
    ///
    /// Callers are the three batch entry points (startCaptioning,
    /// startAnalyzing, startCatalogWideDossier), each AFTER its
    /// `isShuttingDown` guard — so a dead runner can never be
    /// resurrected during app teardown.
    func acquireRunner() -> CaptionRunner {
        runnerIdleTimer?.cancel()
        runnerIdleTimer = nil
        if let cached = cachedRunner {
            captionOrchLog.info("VLM keep-alive: reusing cached runner (\(cached.modelID, privacy: .public)) — no model reload")
            return cached
        }
        let runner = runnerFactory()
        cachedRunner = runner
        return runner
    }

    /// Arm the idle release. Called on every batch settle path (after
    /// `await activeTask?.value` in each entry point). No-op when
    /// nothing is cached or when shutdown already began.
    ///
    /// Concurrency shape: `Task { @MainActor [weak self] ... }` — the
    /// timer body always runs on the MainActor (this class's isolation,
    /// so the drop is an ordinary property write, no locking), `weak
    /// self` means it can never fire into a deallocated orchestrator,
    /// and a cancel makes the sleep throw so a timer that lost the
    /// race to a new batch never drops the runner that batch just
    /// acquired.
    func armRunnerIdleTimer() {
        runnerIdleTimer?.cancel()
        runnerIdleTimer = nil
        guard cachedRunner != nil, !isShuttingDown else { return }
        let window = runnerIdleTimeout
        runnerIdleTimer = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            } catch {
                return  // cancelled — a new batch took the runner over
            }
            guard let self, !Task.isCancelled, !self.isShuttingDown else { return }
            // Belt-and-braces: never drop mid-batch. Shouldn't be
            // reachable (acquireRunner cancels this timer at batch
            // start), but the guard is free and the failure mode —
            // releasing the container under live inference — is the
            // crash class this whole lifecycle is defending against.
            guard !self.currentStatus.isActive else { return }
            captionOrchLog.info("VLM keep-alive: idle window (\(Int(window))s) expired — releasing cached runner and model container")
            self.cachedRunner = nil
            self.runnerIdleTimer = nil
        }
    }

    /// Shutdown teardown: cancel the idle timer and drop the cached
    /// runner NOW. Called from beginShutdown() and drainForShutdown()
    /// (CaptionOrchestrator+Lifecycle) — quitting mid-idle-window must
    /// release our container reference immediately so the AppDelegate
    /// MLX teardown (synchronize + _exit backstop, MLXShutdown.swift)
    /// is quiescing a GPU nothing can re-dispatch to. A batch that is
    /// still draining holds its own local `runner` reference; that one
    /// releases when the drain settles (or is bypassed by the _exit
    /// backstop on a blown deadline), same as before this cache.
    func dropCachedRunnerForShutdown() {
        runnerIdleTimer?.cancel()
        runnerIdleTimer = nil
        guard cachedRunner != nil else { return }
        shutdownLog.notice("VLM keep-alive: dropping cached runner for shutdown")
        cachedRunner = nil
    }

    /// Latched true by `drainForShutdown()` when the app is quitting.
    /// Every start* entry point bails when set. Without this latch the
    /// catalog-wide sweep loops (startCatalogWideCaptioning /
    /// startCatalogWideDossier) would start the NEXT volume's batch
    /// after the quit-time cancel kills the current one — those loops
    /// run in view-owned Tasks that `cancel()` cannot reach, and fresh
    /// VLM inference dispatching GPU work during app teardown is
    /// exactly the mid-inference exit crash
    /// (VideoScan-2026-06-11-232946.ips).
    // Was `private(set)`: the setter is now written by beginShutdown /
    // drainForShutdown, which live in CaptionOrchestrator+Lifecycle.swift.
    // `private(set)` is file-scoped, so a cross-file extension can't assign
    // it. Widened to a plain `var` (module-internal get+set) — `internal(set)`
    // would be a redundant modifier on an already-internal property.
    // (refactor 2026-06-24)
    var isShuttingDown = false

    init(runnerFactory: (() -> CaptionRunner)? = nil,
         defaults: UserDefaults = .standard) {
        self.framesPerFile = 3
        self.runnerFactory = runnerFactory ?? { MLXVLMCaptionRunner() }
        self.persistenceDefaults = defaults
        // Test-host isolation (Settings-pollution class): an orchestrator
        // created against the REAL standard defaults inside a test host
        // must neither read nor write them. Tests that exercise
        // persistence semantics inject their own UserDefaults(suiteName:).
        self.persistenceEnabled = !(TestEnvironment.isTestHost && defaults === UserDefaults.standard)
        if persistenceEnabled {
            self.analysisScope = AnalysisScope.restored(from: defaults)
            self.activeVolumePrefixes = Set(defaults.stringArray(forKey: Self.activeVolumesPrefsKey) ?? [])
            let restoredQueue = defaults.stringArray(forKey: Self.queuedVolumesPrefsKey) ?? []
            self.queuedVolumePrefixes = restoredQueue
            // A queue restored while DossierAutoResume is OFF shows as
            // PAUSED instead of being silently dropped — nothing starts
            // until the user explicitly resumes (or enqueues) work.
            self.queuePaused = !restoredQueue.isEmpty
                && !defaults.bool(forKey: Self.autoResumePrefsKey)
        }
        // Dashboard snapshot wiring LAST — publishes the initial state
        // (restored queue / paused flag) and subscribes the coalesced
        // ≤2 Hz forwarder. See DossierDashboardSnapshot.swift.
        wireDashboardSnapshot()
    }

    // MARK: - Public API
    //
    // The batch-control entry points (startCaptioning,
    // startCatalogWideCaptioning, cancel, pause, resume,
    // beginShutdown, drainForShutdown) live in
    // CaptionOrchestrator+Lifecycle.swift. The dossier entry points
    // (startAnalyzing, startCatalogWideDossier) and the batch loops
    // (runDossierBatch / runDossierBatchSerial) live in
    // CaptionOrchestrator+Dossier.swift. The single-prompt caption
    // loop (runBatch) and the progress publisher (publishProgress)
    // live in CaptionOrchestrator+Captioning.swift. The live activity
    // / lane bookkeeping lives in CaptionOrchestrator+Activity.swift.
    // Stored state and the type declaration stay here.

    // MARK: - Auto-resume persistence

    /// UserDefaults key for the list of volume prefixes that had an
    /// active dossier batch when the app last ran. On launch, the
    /// VideoScanApp wiring reads this and (if DossierAutoResume is on)
    /// queues them for sequential processing.
    static let activeVolumesPrefsKey = "DossierActiveVolumes"

    /// UserDefaults key for the pending FIFO analyze queue (feature
    /// 2026-07: express intent on several volumes, walk away).
    static let queuedVolumesPrefsKey = "DossierQueuedVolumes"

    /// UserDefaults key for the "Resume on Launch" toggle. ONE constant
    /// (QA F10 2026-07-14) shared by init's paused-restore read, the
    /// VideoScanApp launch wiring, and the dashboard's @AppStorage —
    /// the literal was previously repeated at all three sites. NOTE:
    /// the string is persisted user state — never rename the value.
    static let autoResumePrefsKey = "DossierAutoResume"

    /// Where scope + queue persistence goes. `.standard` in the app;
    /// tests inject a throwaway suite. Set once in init.
    let persistenceDefaults: UserDefaults

    /// False when we're a test host talking to the REAL standard
    /// defaults — all persistence reads/writes become no-ops so tests
    /// can never leak into (or inherit from) the user's live prefs.
    /// `internal` so the queue/scope extension (separate file) can
    /// honor the same gate.
    let persistenceEnabled: Bool

    /// Volume prefixes currently registered as "in progress" for
    /// auto-resume purposes. @Published so the UI can echo it; the
    /// authoritative store is UserDefaults so it survives crash.
    /// Populated from defaults in init (gated by persistenceEnabled —
    /// the old property-initializer read real defaults even in tests).
    @Published private(set) var activeVolumePrefixes: Set<String> = []

    /// `internal` (not `private`) so `startAnalyzing`
    /// (CaptionOrchestrator+Dossier) can register/unregister the active
    /// volume — Swift `private` is file-scoped and the dossier entry
    /// point now lives in a separate file.
    func rememberActiveVolume(_ prefix: String) {
        activeVolumePrefixes.insert(prefix)
        guard persistenceEnabled else { return }
        persistenceDefaults.set(Array(activeVolumePrefixes), forKey: Self.activeVolumesPrefsKey)
    }

    func forgetActiveVolume(_ prefix: String) {
        activeVolumePrefixes.remove(prefix)
        guard persistenceEnabled else { return }
        persistenceDefaults.set(Array(activeVolumePrefixes), forKey: Self.activeVolumesPrefsKey)
    }

    // MARK: - Volume analyze queue + analysis scope (stored state)
    //
    // Behavior lives in CaptionOrchestrator+Queue.swift; a cross-file
    // extension can't add stored properties, so the state lives here.
    // (≈ C++ partial class: data in the primary definition, methods
    // spread across translation units.)

    /// FIFO of volume prefixes waiting to analyze. Head starts when
    /// the current batch settles (finished OR stopped). `internal`
    /// setter (not `private(set)`) because enqueue/dequeue live in the
    /// +Queue extension file — mutate ONLY through those methods.
    @Published var queuedVolumePrefixes: [String] = []

    /// True when a persisted queue was restored with DossierAutoResume
    /// OFF: the queue is visible but nothing auto-starts. Cleared by
    /// any explicit user intent (enqueue / Resume Queue).
    @Published var queuePaused: Bool = false

    /// What kinds of files Analyze spends GPU time on. Restored from
    /// defaults in init; mutate via `updateAnalysisScope(_:)` (which
    /// does the explicit save). `internal` setter for the same
    /// cross-file-extension reason as the queue.
    @Published var analysisScope: AnalysisScope = AnalysisScope()

    /// Latch that closes the enqueue→dispatch race: set synchronously
    /// (MainActor) when a queued volume is handed to a Task, cleared
    /// when its batch settles. Without it, two rapid enqueues while
    /// idle could each dequeue a volume and race startAnalyzing's busy
    /// guard — the loser's volume would be silently dropped.
    ///
    /// Carries the PREFIX (QA F6 2026-07-14), not just a Bool: during
    /// the dequeue→batch-start window the volume is in NEITHER
    /// queuedVolumePrefixes NOR currentVolumePrefix, so enqueueAnalyze
    /// would happily re-queue it (double run, row lies "Queued" while
    /// analyzing). enqueueAnalyze and the row state treat the in-flight
    /// prefix as running. @Published so the row repaints with it.
    @Published var queueDispatchInFlightPrefix: String?

    /// Bool view of the dispatch latch — the guard scheduleQueueAdvance
    /// and the wait-loop pollers read.
    var queueDispatchInFlight: Bool { queueDispatchInFlightPrefix != nil }

    /// Queued volumes currently PARKED because their volume isn't
    /// mounted (QA F2 2026-07-14). Parked volumes STAY in
    /// queuedVolumePrefixes (persisted, dequeueable, visible) but the
    /// queue advance skips past them — dispatching an unmounted prefix
    /// would run the batch's missing-on-disk branch over every record
    /// under it (mass soft-purge) and an offline drive at the head
    /// would otherwise wedge the whole line. Cleared per-prefix when
    /// the volume dispatches or is dequeued. Membership doubles as the
    /// log-once latch so a parked volume doesn't re-log on every
    /// settle's re-advance.
    @Published var parkedVolumePrefixes: Set<String> = []

    // MARK: - Dashboard snapshot (perf/dashboard-render 2026-07-14)
    //
    // The dashboard observes ONLY this snapshot object — never the
    // orchestrator directly — so per-record @Published churn (skip
    // storms, lane mutations, live counters) can't invalidate the
    // dashboard's view graph. Publication machinery lives in
    // DossierDashboardSnapshot.swift; the stored state lives here
    // because a cross-file extension can't add stored properties.

    /// The one object DossierDashboardView observes. Owned here so
    /// the view can grab it off the injected orchestrator reference.
    let dashboardSnapshot = DossierDashboardSnapshot()

    /// Combine subscription for the objectWillChange → snapshot
    /// forwarder (set up in wireDashboardSnapshot; lives as long as
    /// the orchestrator). (`AnyCancellable` ≈ C++ RAII connection
    /// handle — dropping it disconnects.)
    var dashboardSnapshotForwarder: AnyCancellable?

    /// Coalescing latch + interval clock for the ≤2 Hz snapshot
    /// refresh. Plain vars — internal bookkeeping, never observed.
    var dashboardSnapshotRefreshScheduled = false
    var lastDashboardSnapshotPublishAt: CFAbsoluteTime = 0

    // MARK: - Progress publish throttle state (perf/dashboard-render)
    //
    // publishProgress used to fire an UNTHROTTLED @Published write per
    // record — a batch skipping thousands of already-analyzed records
    // machine-gunned objectWillChange. The throttle lives in
    // CaptionOrchestrator+Captioning.swift; the state lives here.

    /// Values of the newest suppressed progress event, delivered by
    /// the trailing flush so the last event of a burst is never lost.
    struct PendingProgress {
        let idx: Int
        let total: Int
        let currentFile: String
        let started: CFAbsoluteTime
    }
    var pendingProgress: PendingProgress?
    var progressFlushScheduled = false
    var lastProgressPublishAt: CFAbsoluteTime = 0

    /// 250 ms → ≤4 Hz, matching the AnalyzeJob/MFO forwarder cadence
    /// (the established throttle template, AnalyzeJob.swift init).
    static let progressPublishMinInterval: CFAbsoluteTime = 0.25

    // MARK: - Per-reason skip/fail counters (batch observability)
    //
    // 2026-07-14 perf diagnosis: 1,097 wasted extraction attempts in a
    // nightly batch produced ~1 log line total. The batch loops bump
    // these per reason and the batch-done summary prints the split.
    // Plain vars (not @Published): read only for the summary line.

    var liveSkipAlreadyAnalyzed = 0
    var liveSkipMissing = 0
    var liveSkipProtected = 0

    /// Test seam / regression sensor (QA F5 2026-07-14): counts every
    /// ENTRY into `startAnalyzing`, successful or refused. AnalyzeJob's
    /// wait loop must poll a plain bool while the orchestrator is busy
    /// instead of calling startAnalyzing per tick (each refusal logged
    /// a warning — N waiting jobs behind an hours-long batch produced
    /// tens of thousands of lines). Plain var, never published.
    var startAnalyzingAttempts = 0

    // MARK: - In-flight counts
    //
    // The progress sheet needs to show captioned/skipped/failed counts
    // *during* the run, not just at the end. The batch loop updates
    // these as it goes; the sheet observes them via @Published.

    @Published var liveCaptioned: Int = 0
    @Published var liveSkipped: Int = 0
    @Published var liveFailed: Int = 0
    @Published var liveCurrentIndex: Int = 0
    @Published var liveTotal: Int = 0

    /// Whisper-stage failures during the current batch. A whisper
    /// failure still produces a valid VLM-only dossier — the file IS
    /// captioned, not failed — so we deliberately do NOT roll this
    /// into `liveFailed` (which is reserved for files that couldn't
    /// be dossiered at all). Separate counter so the dashboard can
    /// surface "transcribed N/M" honesty later. Reset alongside the
    /// other live counts at the top of each batch.
    @Published var transcriptFailures: Int = 0

    // MARK: - Live pipeline activity state
    //
    // Drives the dashboard's "Now Analyzing" / "Recently Completed"
    // panels. All mutation happens on the MainActor (the class is
    // @MainActor — including the chained Whisper tasks, which are
    // declared `Task { @MainActor in ... }`), so plain array writes
    // are safe without locking.

    /// In-flight stage lanes ("Now Analyzing"). Cleared when a batch
    /// settles — finished OR cancelled.
    @Published var activeLanes: [PipelineLane] = []

    /// Completed-file history ("Recently Completed") — newest first,
    /// capped at `recentActivityCap`. Deliberately NOT cleared at
    /// batch end: history persists until the next app run.
    @Published var recentActivity: [CompletedActivity] = []

    /// Hard cap on the history list. 8 rows fit the dashboard without
    /// scrolling; also the memory bound (a handful of small structs —
    /// worst case well under 8 KB).
    static let recentActivityCap = 8
}

// MARK: - Frame-timestamp helper
//
// `internal` so the test target can exercise it directly. Free
// function (not orchestrator method) so it stays pure and side-effect
// free — easy to unit-test without an orchestrator instance.

/// Returns N timestamps evenly spaced across the clip, skipping the
/// first and last 5%. Always returns exactly `framesPerFile` entries
/// (or fewer if the duration is unusably short).
func framesEvenlySpaced(framesPerFile: Int, durationSec: Double) -> [Double] {
    guard framesPerFile > 0, durationSec > 0 else { return [] }
    let safe = max(0.1, durationSec)
    // Avoid the first/last 5%. For a 3-second clip this is
    // 0.15s..2.85s — comfortably away from the leader/trailer.
    let lo = safe * 0.05
    let hi = safe * 0.95

    if framesPerFile == 1 {
        return [(lo + hi) / 2.0]
    }
    let stride = (hi - lo) / Double(framesPerFile - 1)
    return (0..<framesPerFile).map { i in lo + Double(i) * stride }
}
