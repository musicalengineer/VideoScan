// AnalyzeCyclers.swift
// The knowledge kinds the Analyze panel shows, one row each
// (Rick 2026-10-02, docs/design/analyze_knowledge_and_storage_actions_2026-10-02.md
// §5.5 "governing distinction"):
//
//   MFO = file operations a person started (Combine, Trim, Delete on X…).
//   Analyze = continuous background metadata cyclers — no "done", only
//   "current"; natural state is running quietly or paused.
//
// THREE INTEGRITY ROWS come first (Rick 2026-10-16, Catalog Status
// freshness §2): File Presence (Audit Catalog tier 0), Full Hashes
// (SHA-256) and Sound Prints (audio fingerprints). They are cyclers by
// Rick's own definition — no "done", only "current" — but their work reads
// files for minutes to hours, so each Run now starts the MEDIA FILE
// OPERATION that already exists (AUDIT, the hash backfill, SOUND PRINT);
// the panel's band mirrors that job's row (§2.1). Then the nine metadata
// cyclers of the 10/2 trial.
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

/// One knowledge kind. Raw values are stable keys (UserDefaults, logs,
/// the FreshnessRow.kind the summary band keys on).
enum AnalyzeCycler: String, CaseIterable, Identifiable, Sendable {
    // Integrity — "does the catalog still describe the files?" First.
    case filePresence    = "filePresence"
    case fullHashes      = "fullHashes"
    case soundPrints     = "soundPrints"
    /// Verify Catalog (2026-10-16, integrity first): the catalog's own rows,
    /// stamps and relations against their constraints; reads
    /// integrity-latest.json. AFTER the three integrity rows.
    case integrity       = "integrity"
    // Metadata cyclers (10/2 trial order).
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

    /// The integrity kinds, in registry order — each backed by an MFO job.
    static let integrityJobs: [AnalyzeCycler] = [.filePresence, .fullHashes, .soundPrints, .integrity]

    /// True for the kinds whose work is a Media File Operation (the band
    /// mirrors the MFO row; Pause / Stop act on the job).
    var isIntegrity: Bool {
        switch self {
        case .filePresence, .fullHashes, .soundPrints, .integrity: return true
        default: return false
        }
    }

    /// Row title — plain words, the verb the design doc uses.
    var title: String {
        switch self {
        case .filePresence:   return "File Presence"
        case .fullHashes:     return "Full Hashes"
        case .soundPrints:    return "Sound Prints"
        case .integrity:      return "Integrity"
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
        case .filePresence:   return "File Presence"
        case .fullHashes:     return "Full Hashes"
        case .soundPrints:    return "Sound Prints"
        case .integrity:      return "Integrity"
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
        case .filePresence:   return "doc.text.magnifyingglass"
        case .fullHashes:     return "checkmark.seal"
        case .soundPrints:    return "waveform.badge.magnifyingglass"
        case .integrity:      return "checkmark.shield"
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
        case .filePresence:
            return "Checks that every catalog entry on a connected drive still points at its file (one stat per file, nothing is opened). A file that is gone is marked Missing; a Missing file that is back is shown again."
        case .fullHashes:
            return "Reads each file once in full and keeps its SHA-256, so two copies can be proved byte-for-byte identical. A sampled hash from a scan does not count."
        case .soundPrints:
            return "Listens to each file once and keeps a small fingerprint of its sound, so copies and clips of the same recording can be told apart. Kept in a sidecar beside the catalog."
        case .integrity:
            return "Verify Catalog: checks the catalog itself — ids, paths, lineage, fixity digests, the removal markers, the sound prints against each file's header, the catalog file's own hash — and writes a dated report beside the catalog. Nothing on media is opened; nothing is changed."
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
    /// the dossier pipeline (orchestrator pause), Find Similar Footage
    /// (its MFO job pauses at phase boundaries) and the three integrity
    /// jobs (each pauses between chunks / files). The rest say so.
    var isPausable: Bool {
        isDossierStage || self == .footage || isIntegrity
    }

    /// Help text for a disabled Pause control.
    static let notPausableHelp = "Can't be paused yet — once started, this pass runs to the end. Pausing is coming later."

    /// Whether the engine today offers a per-volume scope the panel can
    /// hand it (the row's disclosure shows a per-volume breakdown).
    var hasVolumeScope: Bool {
        switch self {
        case .duplicates, .footage, .sceneCaptions, .ocr, .transcribe, .fileSignatures:
            return true
        case .filePresence, .fullHashes, .soundPrints, .integrity, .correlate, .embeddedDates, .dateInference:
            // The integrity jobs run every connected drive in parallel
            // lanes; Correlate and the backfills take a path prefix too,
            // but their coverage is catalog-shaped (pairs; "has a tag").
            return false
        }
    }

    /// What ALREADY runs by itself today, so the schedule menu's "Auto"
    /// tells the truth: File Presence (the nightly's `--audit-catalog`),
    /// Date Inference (on load / live reload / each dossier result), Find
    /// Similar Footage (the Archive Angel's keep-current run) and the
    /// dossier queue (Resume on launch).
    var autoRunsToday: Bool {
        switch self {
        case .filePresence, .dateInference, .footage, .sceneCaptions, .ocr, .transcribe: return true
        case .fullHashes, .soundPrints, .integrity, .duplicates, .correlate, .fileSignatures, .embeddedDates: return false
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

    static let phaseAHelp = "Scheduling is coming later. For now this only changes the label; Auto shows what already runs on its own today."

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
                ? .auto(detail: Self.coverageUnknownDetail)
                : .manual(detail: Self.coverageUnknownDetail)
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
            return .manual(detail: "\(left) · \(schedule.title) is coming later; by hand for now")
        case .manual:
            return .manual(detail: left)
        }
    }

    /// The row's words when nothing records this cycler's check per file.
    static let coverageUnknownDetail = "coverage unknown — nothing records this check yet"

    static func relative(_ date: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }
}
