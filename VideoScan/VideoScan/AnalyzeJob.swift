import Combine
import Foundation
import os

// MARK: - AnalyzeJob
//
// "Analyze This File" — runs the orchestrator's VLM + Whisper pipeline
// on a single record. Rick 2026-06-14: the Media File Operations window
// owns per-file operations; the Analyze Dashboard owns batch volume-wide
// operations. This split keeps the dashboard focused on "how is this
// VOLUME doing overall" while the operations window shows "what's
// happening to THIS file right now."
//
// Architecturally: AnalyzeJob is a UI proxy for one round of
// orchestrator.startAnalyzing(volumePrefix:). The trick is that
// startAnalyzing's candidate filter uses fullPath.hasPrefix, so passing
// the record's exact fullPath matches only that one record. Single-file
// batch falls out for free without a new orchestrator entry point.
//
// Constraints:
//   - Phase 1 caps at one orchestrator-active operation. If the
//     orchestrator is currently busy with a volume batch, the menu
//     item is disabled (and AnalyzeJob.start refuses with a clear
//     failure message). Phase 2 (true parallel) could lift this.
//   - Cancel routes through orchestrator.skipLane targeting the
//     in-flight Whisper lane, which SIGTERMs Python within ~200ms.
//
// Progress: derived from orchestrator's @Published state.
//   0.00 → batch starting (model loading, candidate filter)
//   0.50 → VLM completed, Whisper running
//   1.00 → both stages complete
// Coarse but accurate enough for a single-file UX. Finer progress would
// require per-frame signals from the VLM runner; deferred.

private let analyzeJobLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                   category: "fileOps")

/// Which stages of the pipeline an AnalyzeJob runs. Rick 2026-06-14:
/// Transcribe Audio and Generate Scene Captions are independent
/// MFO verbs, with Analyze as the convenience verb that does both.
/// AnalyzeJob takes a Set so a future Phase could add a third stage
/// (e.g. "Identify Family") without changing the call surface.
enum AnalyzeStage: String, Hashable, Sendable {
    case captions   // VLM on video frames
    case transcript // Whisper on audio

    /// The "do everything" default — both stages, gated by the
    /// record's stream type. AnalyzeJob's pre-flight prunes
    /// inapplicable stages (e.g. transcript dropped on video-only).
    static let all: Set<AnalyzeStage> = [.captions, .transcript]
}

@MainActor
final class AnalyzeJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .analyze
    let startedAt = Date()
    let record: VideoRecord
    /// Stages this job is responsible for. Set at init by the menu
    /// item that kicked the job (Analyze = both; Transcribe Audio =
    /// `[.transcript]`; Generate Scene Captions = `[.captions]`).
    let stages: Set<AnalyzeStage>

    private weak var model: VideoScanModel?
    private weak var orchestrator: CaptionOrchestrator?

    let canPause = false

    @Published private(set) var state: MediaFileOperationState = .running
    @Published private(set) var subtitleText: String
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue: Bool = true

    /// Subscription that re-publishes the orchestrator's @Published
    /// changes as ours, so the row view re-renders on every state tick.
    private var orchestratorForwarder: AnyCancellable?

    /// The run Task — internal so tests can await terminal state.
    private(set) var task: Task<Void, Never>?

    /// True once the orchestrator emits the first lane FOR THIS record.
    /// Until then the row says "Queued" instead of staying confusingly
    /// at "0% — extracting" for the 1-2s the model load takes.
    private var sawFirstLane = false

    var title: String { record.filename }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }

    /// Capitalized verb derived from `stages` — used as the row badge
    /// AND as the leading word in every user-facing status string for
    /// this job. One source of truth: badge, subtitle, success, and
    /// empty-result text all read off this.
    var displayBadge: String { Self.verb(for: stages) }

    private static func verb(for stages: Set<AnalyzeStage>) -> String {
        switch stages {
        case [.transcript]: return "Transcribe"
        case [.captions]:   return "Captions"
        default:            return "Analyze"
        }
    }

    init(record: VideoRecord,
         model: VideoScanModel,
         orchestrator: CaptionOrchestrator,
         stages: Set<AnalyzeStage> = AnalyzeStage.all) {
        self.record = record
        self.model = model
        self.orchestrator = orchestrator
        self.stages = stages
        self.subtitleText = "Queued for \(Self.verb(for: stages).lowercased())…"
        // Subscribe to orchestrator changes so the row updates live.
        self.orchestratorForwarder = orchestrator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                self.updateProgress()
            }
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.runAnalyze()
        }
    }

    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        subtitleText = "Cancelling…"
        // If we have a lane for this record's path, skip it (SIGTERM
        // the Whisper subprocess if Whisper-stage). Otherwise fall
        // back to cancelling our own task — the orchestrator's batch
        // loop will exit before the next iteration.
        if let orchestrator = orchestrator {
            if let lane = orchestrator.activeLanes.first(where: { $0.path == record.fullPath }) {
                orchestrator.skipLane(lane.id)
            } else {
                orchestrator.cancel()
            }
        }
        task?.cancel()
    }

    // MARK: - Run

    private func runAnalyze() async {
        guard let model = model, let orchestrator = orchestrator else {
            await finish(failed: "Lost model or orchestrator reference")
            return
        }

        // Refuse if the orchestrator is already busy — Phase 1
        // serializes per-file behind volume-wide batches.
        guard !orchestrator.currentStatus.isActive else {
            await finish(failed: "Orchestrator busy — stop the current volume batch first or wait for it to finish")
            return
        }

        // Source file existence — same gate the orchestrator's loop
        // applies. Catching it here gives a cleaner row message.
        guard FileManager.default.fileExists(atPath: record.fullPath) else {
            await finish(failed: "Source file missing on disk")
            return
        }

        subtitleText = "Loading model…"
        isIndeterminateValue = true

        analyzeJobLog.info("analyze: \(self.record.filename, privacy: .public) — single-file batch")

        // startAnalyzing's candidate filter uses fullPath.hasPrefix,
        // so passing the record's exact fullPath matches only this
        // one file. Clean single-record batch with no new
        // orchestrator API.
        await orchestrator.startAnalyzing(
            volumePrefix: record.fullPath,
            model: model,
            stages: stages
        )

        // After the orchestrator returns, the batch is complete. Pick
        // the final state from the record's dossierProcessedAt and
        // the orchestrator's reported counts.
        if Task.isCancelled || state == .cancelling {
            await finish(cancelled: true)
            return
        }

        // Probe the record's POST-analyze state. dossierProcessedAt
        // is set by applyDossier on success; absent on failure.
        if model.records.first(where: { $0.id == record.id })?.dossierProcessedAt != nil {
            await finish(success: successMessage)
        } else {
            // Could be: candidate-filter excluded (DRM/junk/needs reformat),
            // VLM bailed (0 scenes in <1s), or no eligible candidates.
            // The dashboard's batch summary line in the log has more
            // detail; the row keeps it short.
            await finish(failed: emptyResultMessage)
        }
    }

    /// Terminal-success string. Single-stage runs name the artifact
    /// they actually banked; the both-stage form is unchanged.
    private var successMessage: String {
        switch stages {
        case [.transcript]: return "Transcribe complete — transcript banked."
        case [.captions]:   return "Captions complete — scene captions banked."
        default:            return "Analyze complete — captions and transcript banked."
        }
    }

    /// "Orchestrator returned without banking anything" string. The
    /// Reformat hint still applies in both single-stage cases.
    private var emptyResultMessage: String {
        "\(displayBadge) finished but no dossier was banked — check log or run Reformat first."
    }

    /// Translate orchestrator's @Published state to our row's
    /// subtitle/fraction. Called on every orchestrator change.
    private func updateProgress() {
        guard let orchestrator = orchestrator, state == .running else { return }

        // Are we currently in an active lane?
        if let lane = orchestrator.activeLanes.first(where: { $0.path == record.fullPath }) {
            sawFirstLane = true
            isIndeterminateValue = false
            let stageLower = lane.stageName.lowercased()
            if stageLower.contains("whisper") {
                subtitleText = "Transcribing audio…"
                fractionValue = 0.5
            } else {
                subtitleText = "Extracting captions…"
                fractionValue = 0.0
            }
            return
        }

        // No active lane. If we already saw one, the file's been
        // banked or is between stages.
        if sawFirstLane {
            subtitleText = "Finalizing…"
            fractionValue = 0.9
            isIndeterminateValue = false
        }
    }

    // MARK: Finish helpers

    private func finish(success: String) async {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1.0
        isIndeterminateValue = false
        orchestratorForwarder = nil
    }

    private func finish(failed: String) async {
        state = .failed(message: failed)
        subtitleText = failed
        isIndeterminateValue = false
        orchestratorForwarder = nil
        analyzeJobLog.warning("analyze failed: \(failed, privacy: .public)")
    }

    private func finish(cancelled: Bool) async {
        state = .cancelled
        subtitleText = "Cancelled"
        isIndeterminateValue = false
        orchestratorForwarder = nil
    }
}
