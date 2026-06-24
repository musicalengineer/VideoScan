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
// Critical design choice: session-scoped model container.
//
// MLXVLMCaptionRunner.caption (S6a) currently calls
// VLMModelFactory.shared.loadContainer ONCE per call — wasted ~30s on
// every file after the first. The orchestrator builds and reuses a
// CaptionSession that holds the loaded container across files in the
// same batch. Frames serialize through it; the session goes away when
// the batch ends (or is cancelled), and a fresh session is built for
// the next batch.
//
// Worst-case memory footprint: one ModelContainer (~3 GB for the 4-bit
// Qwen2.5-VL-3B weights) + transient CIImage per frame (decoded video
// frame, typically <50 MB) + KV cache (<100 MB). Total ceiling ~3.5 GB.
// Released when the session is torn down at batch end. No per-file
// accumulation — captions are flushed to the catalog and dropped from
// the orchestrator's working set at each boundary.

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
    /// without touching MLX.
    var runnerFactory: () -> CaptionRunner

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

    init(runnerFactory: (() -> CaptionRunner)? = nil) {
        self.framesPerFile = 3
        self.runnerFactory = runnerFactory ?? { MLXVLMCaptionRunner() }
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

    /// Volume prefixes currently registered as "in progress" for
    /// auto-resume purposes. @Published so the UI can echo it; the
    /// authoritative store is UserDefaults so it survives crash.
    @Published private(set) var activeVolumePrefixes: Set<String> = {
        let list = UserDefaults.standard.stringArray(forKey: CaptionOrchestrator.activeVolumesPrefsKey) ?? []
        return Set(list)
    }()

    /// `internal` (not `private`) so `startAnalyzing`
    /// (CaptionOrchestrator+Dossier) can register/unregister the active
    /// volume — Swift `private` is file-scoped and the dossier entry
    /// point now lives in a separate file.
    func rememberActiveVolume(_ prefix: String) {
        activeVolumePrefixes.insert(prefix)
        UserDefaults.standard.set(Array(activeVolumePrefixes), forKey: Self.activeVolumesPrefsKey)
    }

    func forgetActiveVolume(_ prefix: String) {
        activeVolumePrefixes.remove(prefix)
        UserDefaults.standard.set(Array(activeVolumePrefixes), forKey: Self.activeVolumesPrefsKey)
    }

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
