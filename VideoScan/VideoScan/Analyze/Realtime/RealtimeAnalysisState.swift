// RealtimeAnalysisState.swift — what the Realtime Content Analysis window
// renders (Rick 2026-11-05 evening: "show the content analyzer in progress
// with pretty (truthful) graphics demonstrating its inputs, work, analyzers,
// melting silicon, and outputs"). Three panes, three sources:
//
//   inApp    the CaptionOrchestrator's own counters and lanes (captions +
//            transcripts), copied as values — never the orchestrator itself;
//   helper   VideoScan Background (the era job): its XPC status, a read-only
//            tally of its journal's newest day file, and its try counts;
//   machine  CPU / GPU / memory / disk read, each a reading WITH its source,
//            or the reason it could not be read.
//
// Every number here is a copy of a fact a source already holds; nothing is
// derived from a remembered field, and nothing is estimated except the
// orchestrator's own ETA (which is shown as its ETA). Equatable so the store
// can drop a publish that changed nothing (DossierDashboardSnapshot's gate).
//
// Memory: ≤ 2 lanes + ≤ 8 outputs + ≤ 8 helper observations + 4 × 60 machine
// samples ≈ under 32 KB. No per-record state.
//
// (For Rick: a plain struct of plain structs — the "view model" a C++ UI
// would copy out under a lock; the window reads it, never the engines.)

import Foundation
import VideoScanCore

struct RealtimeAnalysisState: Equatable, Sendable {

    // MARK: In-app analysis (captions + transcripts)

    enum Phase: String, Equatable, Sendable {
        case idle = "Idle"
        case analyzing = "Analyzing"
        case paused = "Paused"
        case stopping = "Stopping"
        case finished = "Finished"
    }

    /// One file in the pipeline right now — a copy of `PipelineLane`.
    struct Lane: Equatable, Sendable, Identifiable {
        var id: UUID
        var filename: String
        var path: String
        var recordID: UUID?
        /// "MLXVLM" / "Whisper" (CaptionOrchestrator.stageDisplayName).
        var stage: String
        /// "extracting scenes…" / "transcribing audio…" / "waiting for prior transcript…".
        var verb: String
        var startedAt: Date
        var framesPlanned: Int
        var clipSeconds: Double
        /// Scenes were extracted — they exist in memory until applyDossier
        /// banks them at the lane's end (Codex F1: never "banked" here).
        var hasCaptions: Bool
        var isVideoOnly: Bool
        var noSpeech: Bool = false
        /// The extractor returned (with or without scenes) — an explicit fact,
        /// never inferred from the output (re-review 2, finding 3).
        var extractionDone: Bool = false

        var isTranscribing: Bool { stage.lowercased().contains("whisper") }

        /// "N frames to rip" is shown only while the extractor is still on them.
        var showsFramesToRip: Bool { framesPlanned > 0 && !extractionDone }

        /// The OUT column while the file is still in flight: nothing has
        /// reached the catalog yet, and the words say so.
        var outWords: String {
            hasCaptions ? "scenes extracted — banks after the transcript" : "…"
        }
    }

    /// One file that finished — a copy of `CompletedActivity`.
    struct Output: Equatable, Sendable, Identifiable {
        var id: UUID
        var filename: String
        var path: String
        var recordID: UUID?
        var syncedAt: Date
        var vlmSeconds: Double?
        var whisperSeconds: Double?
        var note: String?
        var isVideoOnly: Bool
        var hasCaptions: Bool
        var hasTranscript: Bool
        var transcriptFailed: Bool
        var sceneCount: Int
        var firstCaption: String?
        var transcriptExcerpt: String?
        /// Whisper ran and found no speech (banked as an empty transcript).
        var noSpeech: Bool = false
        /// applyDossier's answer: the words reached the catalog row.
        var banked: Bool = true

        /// The transcript indicator's words: transcript · no speech · no audio · the note.
        var transcriptWords: String {
            if hasTranscript { return "transcript" }
            if noSpeech { return "no speech" }
            if isVideoOnly { return "no audio" }
            return note ?? "no transcript"
        }

        /// Words under a row whose output never reached the catalog; nil when it did.
        var bankWords: String? {
            banked ? nil : "not banked — no catalog row at this path"
        }

        /// VLM + Whisper seconds when BOTH stages that ran were timed; nil
        /// otherwise (Codex F8: an untimed stage is never 0 s). A video-only
        /// file has no Whisper stage to time.
        var timedSeconds: Double? {
            guard let vlm = vlmSeconds else { return nil }
            if isVideoOnly { return vlm }
            guard let whisper = whisperSeconds else { return nil }
            return vlm + whisper
        }
    }

    struct InApp: Equatable, Sendable {
        var phase: Phase = .idle
        var currentFile: String = ""
        var currentIndex: Int = 0
        var total: Int = 0
        /// The orchestrator's own ETA (`CaptionJobStatus.running(etaSec:)`); nil = it has none.
        var etaSeconds: Int?
        var lanes: [Lane] = []
        var recent: [Output] = []
        /// Files done this pass (`liveCaptioned`, the batch's own OUTCOME count).
        var done: Int = 0
        /// Files whose captions (≥ 1 scene) banked (`liveWithCaptions`) — Codex F2.
        var captioned: Int = 0
        var transcribed: Int = 0
        /// Whisper ran and found no speech (`liveNoSpeech`) — Codex F3.
        var noSpeech: Int = 0
        var transcriptFailures: Int = 0
        var failed: Int = 0
        var skipped: Int = 0
        /// The volume (or the one file's path) the batch is on; nil when idle.
        var volumePrefix: String?

        var isWorking: Bool { !lanes.isEmpty }

        /// The header's second line, as rendered (tests read the words).
        var headline: String {
            switch phase {
            case .idle: return "Idle — no captions or transcripts running"
            case .finished: return "Finished — \(done) analyzed · \(skipped) skipped · \(failed) failed"   // files done, not captions (re-review 4)
            case .stopping: return "Stopping — the file in flight banks what it has"
            case .analyzing, .paused:
                var parts: [String] = []
                if total > 0 { parts.append("\(currentIndex) / \(total)") }
                parts.append(RealtimeAnalysisState.secondsPerFileWords(secondsPerFile, over: timedCount))
                parts.append(RealtimeAnalysisState.etaWords(etaSeconds))
                return parts.joined(separator: " · ")
            }
        }

        /// The files of `recent` whose every stage was timed.
        var timedCount: Int { recent.compactMap(\.timedSeconds).count }

        /// Mean wall-clock seconds per finished file over the fully timed
        /// files of `recent`; nil until one is.
        var secondsPerFile: Double? {
            let timed = recent.compactMap(\.timedSeconds)
            guard !timed.isEmpty else { return nil }
            return timed.reduce(0, +) / Double(timed.count)
        }
    }

    // MARK: The background helper (era)

    enum HelperAvailability: Equatable, Sendable {
        /// Nothing read yet (the window just opened): no claim either way.
        case unknown
        /// VideoScan Background is off in Settings; asking would start it, so we don't.
        case disabled
        /// Enabled, but the XPC status call failed (the words say why).
        case silent(String)
        case answered
    }

    struct HelperJob: Equatable, Sendable {
        var stateWords: String
        var completedUnits: Int
        var totalUnits: Int
        var startedAt: Date?
    }

    struct Helper: Equatable, Sendable {
        /// Unknown until the first XPC answer (or the Settings check) lands —
        /// the pane never says "off" or shows zeros from no evidence (re-review 2).
        var availability: HelperAvailability = .unknown
        var backoffWords: String?
        /// The newest era job the helper reports (active or last finished).
        var era: HelperJob?
        /// The helper's own plan size for the era kind (`ServiceStatus.planned`).
        var planned: Int?
        /// Unavailable ("not read yet") until the first fold of the journal lands.
        var tally: HelperJournalTally = .unavailable(file: nil, HelperJournalTally.notReadYet)
        // No "tries in progress" here (Codex re-review 1/2/6, Rick's KISS): that
        // number needs the catalog plus every journal day file; the Results
        // sheet owns the rule and the window points at it.
        /// "Background: N journal lines waiting · M refused" (JournalApplierWords).
        var journalWords: String?
        /// The analyzer's short name ("8B").
        var modelShortName: String = ""

        /// One honest progress phrase (Rick's demo rule: plain words, no
        /// plumbing). The run's "N of M files" is this run's unit count; the
        /// helper's plan size is shown only when no run is on.
        static func progressWords(availability: HelperAvailability, era: HelperJob?, planned: Int?, backoff: String?) -> String {
            switch availability {
            case .unknown: return "reading…"
            case .disabled: return "off in Settings"
            case .silent(let why): return "not answering — \(why)"
            case .answered: break
            }
            guard let era else {
                if let planned, planned > 0 { return "no run on now · \(planned.formatted()) files planned for the next run" }
                return "answered — no era job"
            }
            var words = era.stateWords
            if era.totalUnits > 0 {
                words += " · \(era.completedUnits.formatted()) of \(era.totalUnits.formatted()) files in this run"
            }
            if let backoff, backoff != BackoffState.full.words { words += " · pace \(backoff)" }
            return words
        }

        var progressWords: String {
            Self.progressWords(availability: availability, era: era, planned: planned, backoff: backoffWords)
        }
    }

    // MARK: The machine

    /// One counter: a value with its unit and source, or the reason it is absent.
    struct Reading: Equatable, Sendable {
        var value: Double?
        /// "%", "GB", "MB/s".
        var unit: String
        /// Where the number comes from (the tooltip).
        var source: String
        /// Why there is no value (shown as "—" with this in the tooltip).
        var problem: String?
        /// The last ≤ `historyCap` values, oldest first (the sparkline).
        var history: [Double] = []

        static let historyCap = 60

        /// The words beside the tile: the value or "—".
        var words: String {
            guard let value else { return "—" }
            switch unit {
            case "%": return "\(Int(value.rounded()))%"
            case "GB": return String(format: "%.1f GB", value)
            case "MB/s": return value >= 100 ? String(format: "%.0f MB/s", value) : String(format: "%.1f MB/s", value)
            default: return String(format: "%.1f %@", value, unit)
            }
        }

        var tooltip: String {
            if let problem { return "\(source) — \(problem)" }
            return source
        }
    }

    struct Machine: Equatable, Sendable {
        var cpu = Reading(value: nil, unit: "%", source: MachineCounterSource.cpu, problem: "not sampled yet")
        var gpu = Reading(value: nil, unit: "%", source: MachineCounterSource.gpu, problem: "not sampled yet")
        var memory = Reading(value: nil, unit: "GB", source: MachineCounterSource.memory, problem: "not sampled yet")
        var diskRead = Reading(value: nil, unit: "MB/s", source: MachineCounterSource.diskRead, problem: "not sampled yet")
        var memoryTotalGB: Double = 0
        var sampledAt: Date?

        /// Fold one sample in: the value replaces, the history appends (bounded).
        mutating func apply(_ sample: MachineSample, at: Date) {
            func fold(_ r: inout Reading, _ v: Double?, _ problem: String?) {
                r.value = v
                r.problem = problem
                if let v {
                    r.history.append(v)
                    if r.history.count > Reading.historyCap { r.history.removeFirst(r.history.count - Reading.historyCap) }
                }
            }
            fold(&cpu, sample.cpuBusyPercent, sample.cpuProblem)
            fold(&gpu, sample.gpuUtilizationPercent, sample.gpuProblem)
            fold(&memory, sample.memoryUsedGB, sample.memoryProblem)
            fold(&diskRead, sample.diskReadMBPerSecond, sample.diskProblem)
            memoryTotalGB = sample.memoryTotalGB
            sampledAt = at
        }
    }

    var inApp = InApp()
    var helper = Helper()
    var machine = Machine()
    /// When the window opened (the header's "watching since").
    var openedAt: Date?

    // MARK: "Analyze the N left" (Rick 2026-11-06)

    /// What is left, from the coverage report Catalog Status ▸ Content reads.
    var left = AnalyzeLeftPlan()
    /// An engine the plan would start is running now (a pass from elsewhere).
    var leftEnginesBusy = false
    /// A run this window started has not finished yet.
    var leftRunActive = false

    // MARK: "See what we learned" (Rick 2026-11-06)

    /// When the pass this window watched began (the transition into
    /// Analyzing, or "Analyze the N left"'s START); the Observations window
    /// is scoped to every observation stamped since then.
    var passStartedAt: Date?

    /// The hand-off shows once the pass has finished and we know when it started.
    var showsSeeWhatWeLearned: Bool { inApp.phase == .finished && passStartedAt != nil }

    /// Nothing is running here or in the plan's engines.
    var isIdleForLeft: Bool {
        !(inApp.phase == .analyzing || inApp.phase == .paused || inApp.phase == .stopping)
            && !leftEnginesBusy && !leftRunActive
    }

    /// The button shows only when nothing runs (Pause / Stop own that time);
    /// it is enabled only when something is left.
    var showsAnalyzeLeft: Bool { isIdleForLeft }
    var canAnalyzeLeft: Bool { isIdleForLeft && !left.isEmpty }

    // MARK: Words (pure; the view and the tests read them)

    static func etaWords(_ seconds: Int?) -> String {
        guard let seconds, seconds >= 0 else { return "ETA —" }
        if seconds < 60 { return "ETA under a minute" }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 90 { return "ETA \(minutes) min" }
        let hours = Double(seconds) / 3600
        return String(format: "ETA %.1f h", hours)
    }

    static func secondsPerFileWords(_ s: Double?, over n: Int) -> String {
        guard let s, n > 0 else { return "— s/file" }
        return String(format: "%.1f s/file (last %d)", s, n)
    }

    static func elapsedWords(since start: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    static func clipWords(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s) s of media" : "\(s / 60) min \(s % 60) s of media"
    }
}
