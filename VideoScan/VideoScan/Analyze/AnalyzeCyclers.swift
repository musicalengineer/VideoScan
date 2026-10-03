// AnalyzeCyclers.swift
// The nine METADATA CYCLERS the Analyze panel shows, one row each
// (Rick 2026-10-02, docs/design/analyze_knowledge_and_storage_actions_2026-10-02.md
// §5.5 "governing distinction"):
//
//   MFO = file operations a person started (Combine, Trim, Delete on X…).
//   Analyze = continuous background metadata cyclers — no "done", only
//   "current"; natural state is running quietly or paused.
//
// PHASE A TRIAL. This file is the registry the UI reads: display names,
// order, icons, help, which engine flag means "running", whether the
// engine can pause today, and the per-cycler schedule preference
// (stored, but in Phase A it only changes the label — scheduling itself
// arrives in Phase C). No engine code is touched; every "Run now" is
// wired to an entry point that already exists.
//
// (For Rick: `enum … : CaseIterable` ≈ a C++ enum class plus a static
// `allCases` array in declaration order — the row order IS this order.)

import Foundation

/// One metadata cycler. Raw values are stable keys (UserDefaults, logs).
enum AnalyzeCycler: String, CaseIterable, Identifiable, Sendable {
    case duplicates      = "duplicates"
    case footage         = "footage"
    case sceneCaptions   = "sceneCaptions"
    case ocr             = "ocr"
    case transcribe      = "transcribe"
    case correlate       = "correlate"
    case fileSignatures  = "fileSignatures"
    case embeddedDates   = "embeddedDates"
    case dateInference   = "dateInference"

    var id: String { rawValue }

    /// Row title — plain words, the verb the design doc uses.
    var title: String {
        switch self {
        case .duplicates:     return "Detect Duplicates"
        case .footage:        return "Find Similar Footage"
        case .sceneCaptions:  return "Scene Captions"
        case .ocr:            return "OCR"
        case .transcribe:     return "Transcribe"
        case .correlate:      return "Correlate A/V"
        case .fileSignatures: return "File Signatures"
        case .embeddedDates:  return "Embedded Dates"
        case .dateInference:  return "Date Inference"
        }
    }

    /// Short noun for the toolbar menu rows ("Duplicates — current · …").
    var menuTitle: String {
        switch self {
        case .duplicates:     return "Duplicates"
        case .footage:        return "Similar Footage"
        case .sceneCaptions:  return "Scene Captions"
        case .ocr:            return "OCR"
        case .transcribe:     return "Transcripts"
        case .correlate:      return "A/V Pairs"
        case .fileSignatures: return "File Signatures"
        case .embeddedDates:  return "Embedded Dates"
        case .dateInference:  return "Inferred Dates"
        }
    }

    var systemImage: String {
        switch self {
        case .duplicates:     return "doc.on.doc"
        case .footage:        return "square.stack.3d.up"
        case .sceneCaptions:  return "text.below.photo"
        case .ocr:            return "text.viewfinder"
        case .transcribe:     return "waveform"
        case .correlate:      return "arrow.triangle.2.circlepath"
        case .fileSignatures: return "number.square"
        case .embeddedDates:  return "calendar.badge.clock"
        case .dateInference:  return "calendar"
        }
    }

    /// What this cycler records, in one sentence (the row's help).
    var help: String {
        switch self {
        case .duplicates:
            return "Groups files that are the same bytes and elects the copy to keep. Catalog metadata only; nothing is removed here."
        case .footage:
            return "Records which files are probably the same footage — copies, re-encodes, transcodes, exports. No media is read."
        case .sceneCaptions:
            return "Describes what is on screen, a few frames per file, so the catalog can be searched by what you see."
        case .ocr:
            return "Reads dates and words burned into the picture (camcorder date stamps, title cards)."
        case .transcribe:
            return "Writes down what is said, so the catalog can be searched by what you hear."
        case .correlate:
            return "Matches video-only files with their audio-only partners (Avid MXF pairs)."
        case .fileSignatures:
            return "A short content signature per file, so copies can be recognised across drives."
        case .embeddedDates:
            return "Reads the recording date the camera wrote inside the file."
        case .dateInference:
            return "Works out when a file was recorded from everything the catalog knows about it. Never replaces a date you set."
        }
    }

    /// The three dossier stages share one engine (CaptionOrchestrator);
    /// their rows show the same live state and the same volume queue.
    var isDossierStage: Bool {
        self == .sceneCaptions || self == .ocr || self == .transcribe
    }

    /// Pause/Resume is enabled only where the engine supports it today:
    /// the dossier pipeline (orchestrator pause) and Find Similar Footage
    /// (its MFO job pauses at phase boundaries). The rest say so.
    var isPausable: Bool {
        isDossierStage || self == .footage
    }

    /// Help text for a disabled Pause control.
    static let notPausableHelp = "Not pausable yet — this pass runs to the end once started. Pausing arrives in Phase C."

    /// Whether the engine today offers a per-volume scope the panel can
    /// hand it (the row's disclosure shows a per-volume breakdown).
    var hasVolumeScope: Bool {
        switch self {
        case .duplicates, .footage, .sceneCaptions, .ocr, .transcribe, .fileSignatures:
            return true
        case .correlate, .embeddedDates, .dateInference:
            // Correlate and the backfills take a path prefix too, but their
            // coverage is catalog-shaped (pairs; "has a tag"); kept simple.
            return false
        }
    }

    /// What ALREADY runs by itself today, so the schedule menu's "Auto"
    /// tells the truth: Date Inference (on load / live reload / each
    /// dossier result), Find Similar Footage (the Archive Angel's
    /// keep-current run) and the dossier queue (Resume on launch).
    var autoRunsToday: Bool {
        switch self {
        case .dateInference, .footage, .sceneCaptions, .ocr, .transcribe: return true
        case .duplicates, .correlate, .fileSignatures, .embeddedDates: return false
        }
    }

    /// Default schedule label: reflects what already auto-runs; everything
    /// else is Manual until Phase C wires a scheduler.
    var defaultSchedule: AnalyzeSchedule { autoRunsToday ? .auto : .manual }

    /// UserDefaults key for the stored schedule choice.
    var scheduleKey: String { "analyze.schedule.\(rawValue)" }
}

/// Schedule choice per cycler. STORED in Phase A, HONOURED in Phase C —
/// today it changes the row's label and nothing else (the help says so).
enum AnalyzeSchedule: String, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case overnight = "overnight"
    case manual = "manual"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .overnight: return "Overnight"
        case .manual: return "Manual"
        }
    }

    static let phaseAHelp = "Scheduling arrives in Phase C. For now this only changes the label; Auto shows what already runs on its own today."

    /// Read the stored choice (or the cycler's honest default).
    static func stored(for cycler: AnalyzeCycler, in defaults: UserDefaults = .standard) -> AnalyzeSchedule {
        guard let raw = defaults.string(forKey: cycler.scheduleKey),
              let s = AnalyzeSchedule(rawValue: raw) else { return cycler.defaultSchedule }
        return s
    }
}

/// The state chip on a row (design §5.5: Current / Cycling / Paused /
/// Waiting for drive / Manual / Off).
enum AnalyzeRowState: Equatable, Sendable {
    /// Everything reachable and eligible is covered.
    case current
    /// A pass is running. `detail` = "vol X, N to go · ETA" when known.
    case cycling(detail: String)
    /// The engine is paused (dossier pause, footage job pause, a queue
    /// restored paused from the last session).
    case paused(detail: String)
    /// Work remains only on drives that are not connected.
    case waitingForDrive(detail: String)
    /// Work remains and nothing runs it by itself today.
    case manual(detail: String)
    /// Runs by itself today (Angel / launch resume / load) and has work left.
    case auto(detail: String)
    /// Turned off (not used in Phase A — the schedule menu stores "off"
    /// nowhere yet; kept so the chip vocabulary matches the design).
    case off

    var chipText: String {
        switch self {
        case .current: return "Current"
        case .cycling: return "Cycling"
        case .paused: return "Paused"
        case .waitingForDrive: return "Waiting for drive"
        case .manual: return "Manual"
        case .auto: return "Auto"
        case .off: return "Off"
        }
    }

    var detail: String {
        switch self {
        case .current, .off: return ""
        case .cycling(let d), .paused(let d), .waitingForDrive(let d), .manual(let d), .auto(let d): return d
        }
    }

    var isRunning: Bool {
        if case .cycling = self { return true }
        return false
    }
}

// MARK: - Deriving the row state (pure; tested)

enum AnalyzeRowStateRule {

    /// Live facts about one cycler's engine, sampled on the main actor.
    struct Live: Equatable, Sendable {
        var isRunning = false
        var isPaused = false
        /// Engine's own progress words, when it has any ("Analyzing 1,204
        /// files (37 new)…", a job subtitle). Shown as the Cycling detail.
        var progressText: String = ""
        /// Dossier: volumes queued but offline.
        var parkedVolumes = 0
        /// Dossier: queue restored paused from the last session.
        var queueWaitingFromLastSession = false
        /// Footage: when the Angel's automatic run last started.
        var lastAutoRunAt: Date?
    }

    /// The one rule every row uses. `remaining` = eligible − covered on
    /// reachable drives; `offlineRemaining` = eligible records on drives
    /// not connected (they can't be worked on now).
    static func state(for cycler: AnalyzeCycler,
                      live: Live,
                      remaining: Int,
                      offlineRemaining: Int,
                      coverageKnown: Bool,
                      schedule: AnalyzeSchedule,
                      now: Date = Date()) -> AnalyzeRowState {
        if live.isPaused {
            return .paused(detail: live.queueWaitingFromLastSession
                           ? "waiting from last session — Resume to continue"
                           : (live.progressText.isEmpty ? "resumes where it left off" : live.progressText))
        }
        if live.isRunning {
            var parts: [String] = []
            if !live.progressText.isEmpty { parts.append(live.progressText) }
            if coverageKnown && remaining > 0 { parts.append("\(remaining.formatted()) to go") }
            return .cycling(detail: parts.joined(separator: " · "))
        }
        if live.parkedVolumes > 0 {
            return .waitingForDrive(detail: "\(live.parkedVolumes) volume\(live.parkedVolumes == 1 ? "" : "s") in line, drive not connected")
        }
        guard coverageKnown else {
            // No per-record stamp exists for this cycler yet: say so
            // instead of inventing a percentage.
            return cycler.autoRunsToday
                ? .auto(detail: "coverage unknown — no stamp yet")
                : .manual(detail: "coverage unknown — no stamp yet")
        }
        if remaining == 0 {
            if offlineRemaining > 0 {
                return .waitingForDrive(detail: "\(offlineRemaining.formatted()) on drives not connected")
            }
            return .current
        }
        let left = "\(remaining.formatted()) to go"
        switch schedule {
        case .auto where cycler.autoRunsToday:
            if let last = live.lastAutoRunAt {
                return .auto(detail: "\(left) · last automatic run \(Self.relative(last, now: now))")
            }
            return .auto(detail: left)
        case .auto, .overnight:
            // Stored, not honoured yet — be honest on the row.
            return .manual(detail: "\(left) · \(schedule.title) arrives in Phase C")
        case .manual:
            return .manual(detail: left)
        }
    }

    static func relative(_ date: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }
}
