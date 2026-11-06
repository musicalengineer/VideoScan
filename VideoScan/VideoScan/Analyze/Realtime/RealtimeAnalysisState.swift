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
        var hasCaptions: Bool
        var isVideoOnly: Bool

        var isTranscribing: Bool { stage.lowercased().contains("whisper") }
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
        var captioned: Int = 0
        var transcribed: Int = 0
        var transcriptFailures: Int = 0
        var failed: Int = 0
        var skipped: Int = 0
        /// The volume (or the one file's path) the batch is on; nil when idle.
        var volumePrefix: String?

        var isWorking: Bool { !lanes.isEmpty }

        /// Mean wall-clock seconds per finished file over `recent` (VLM +
        /// Whisper as the orchestrator timed them); nil until one finished.
        var secondsPerFile: Double? {
            let timed = recent.compactMap { o -> Double? in
                guard o.vlmSeconds != nil || o.whisperSeconds != nil else { return nil }
                return (o.vlmSeconds ?? 0) + (o.whisperSeconds ?? 0)
            }
            guard !timed.isEmpty else { return nil }
            return timed.reduce(0, +) / Double(timed.count)
        }
    }

    // MARK: The background helper (era)

    enum HelperAvailability: Equatable, Sendable {
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
        var availability: HelperAvailability = .disabled
        var backoffWords: String?
        /// The newest era job the helper reports (active or last finished).
        var era: HelperJob?
        /// The helper's own plan size for the era kind (`ServiceStatus.planned`).
        var planned: Int?
        var tally: HelperJournalTally = HelperJournalTally()
        /// Files with tries and no verdict (attempts/era.jsonl, seated signer); nil = unreadable.
        var triesInProgress: Int?
        var triesProblem: String?
        /// "Background: N journal lines waiting · M refused" (JournalApplierWords).
        var journalWords: String?
        /// The analyzer's short name ("8B").
        var modelShortName: String = ""
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
