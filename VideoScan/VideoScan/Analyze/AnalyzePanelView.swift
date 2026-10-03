// AnalyzePanelView.swift
// The Analyze panel — a quiet control panel for the metadata cyclers
// (Rick 2026-10-02, design §5.5: "Time Machine's pane, one row per
// cycler"). Replaces the content of the ⇧⌘O window and the Catalog
// toolbar's "Analyze Catalog" button target. PHASE A TRIAL: rewires the
// existing engines into this shape; nothing underneath is refactored.
//
// One row per cycler, in registry order:
//   name · STATE chip (Current / Cycling — N to go / Paused / Waiting for
//   drive / Manual / Auto) · COVERAGE "x of y eligible · z%" with a small
//   "n offline · m not applicable" · Pause/Resume (enabled only where the
//   engine supports it) · Run now · schedule menu (stored; label-only in
//   Phase A) · an optional disclosure with the per-volume breakdown.
//
// OBSERVATION (the 2026-07-14 render-loop lesson): the panel observes TWO
// equality-gated snapshot objects — the model's AnalyzeCoverageSnapshot
// (recomputed off-main on catalog mutation) and the orchestrator's
// DossierDashboardSnapshot (≤2 Hz) — and samples the handful of engine
// flags (isAnalyzingDuplicates, isCorrelating, …, the footage job) on a
// 1 s tick into ONE Equatable @State value, written only when it changed.
// `model`, `orchestrator` and `center` are plain references: reads and
// action calls only. NO O(records) work in this body — every number is
// read from the cached report (AnalyzePanelSensorTests pins it).
//
// (For Rick: `@ObservedObject` ≈ subscribing to an object's change signal;
// a plain `let model` ≈ holding a pointer without subscribing.)

import SwiftUI
import Combine

struct AnalyzePanelView: View {

    let model: VideoScanModel
    let orchestrator: CaptionOrchestrator
    let center: MediaFileOperationsCenter

    @ObservedObject private var coverage: AnalyzeCoverageSnapshot
    @ObservedObject private var dossier: DossierDashboardSnapshot

    @Environment(\.openWindow) private var openWindow
    @AppStorage(CaptionOrchestrator.autoResumePrefsKey) private var autoResume: Bool = false

    @State private var live = AnalyzeLiveSample()
    @State private var expanded: Set<AnalyzeCycler> = []
    @State private var showClearRecorrelateConfirm = false
    /// Bumped after a schedule-menu write so the sampled schedules refresh
    /// on the same frame instead of the next tick.
    @State private var scheduleRevision = 0

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(model: VideoScanModel, orchestrator: CaptionOrchestrator, center: MediaFileOperationsCenter) {
        self.model = model
        self.orchestrator = orchestrator
        self.center = center
        // Property-wrapper backing init (`_coverage` ≈ the wrapper struct
        // itself, not the wrapped value).
        self._coverage = ObservedObject(wrappedValue: model.analyzeCoverageSnapshot)
        self._dossier = ObservedObject(wrappedValue: orchestrator.dashboardSnapshot)
    }

    private var runner: AnalyzeRunner {
        AnalyzeRunner(model: model, orchestrator: orchestrator, center: center)
    }

    // MARK: Body

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                header
                VStack(spacing: 8) {
                    ForEach(AnalyzeCycler.allCases) { cycler in
                        row(cycler)
                    }
                }
                scopeAndResume
                footnote
            }
            .padding(20)
        }
        .frame(minWidth: 760, minHeight: 620)
        .accessibilityIdentifier("analyze.panel")
        .onAppear { sampleLive() }
        .onReceive(tick) { _ in sampleLive() }
        .onChange(of: scheduleRevision) { _, _ in sampleLive() }
        .alert("Clear & Re-correlate All", isPresented: $showClearRecorrelateConfirm) {
            Button("Clear All Pairs & Re-correlate", role: .destructive) {
                runner.clearAndRecorrelateAll(source: "panel")
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This wipes EVERY A/V pairing — including pairs you made by hand — and re-derives them all from file evidence.\n\nNormal \"Run now\" already handles new files and never touches existing pairs. Only use this if the pairings themselves are wrong.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Analyze")
                    .font(.title.weight(.semibold))
                Text("What the catalog keeps current about your files, and how far along each one is. These run in the background; nothing here changes or removes a file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(coverage.report.activeRecords.formatted()) files in the catalog")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if coverage.report.computedAt.timeIntervalSince1970 > 0 {
                    Text("counts as of \(MediaDistributionFormat.timeString(coverage.report.computedAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ cycler: AnalyzeCycler) -> some View {
        let facts = rowFacts(cycler)
        AnalyzeCyclerRow(
            facts: facts,
            isExpanded: expanded.contains(cycler),
            onToggleExpanded: {
                if expanded.contains(cycler) { expanded.remove(cycler) } else { expanded.insert(cycler) }
            },
            onRunNow: { volume in runner.runNow(cycler, volume: volume, source: "panel") },
            onPause: { runner.pause(cycler); sampleLive() },
            onResume: { runner.resume(cycler); sampleLive() },
            onStop: { runner.stop(cycler); sampleLive() },
            onSetSchedule: { s in
                UserDefaults.standard.set(s.rawValue, forKey: cycler.scheduleKey)
                model.log("Analyze: \(cycler.title) — schedule set to \(s.title) (label only for now)")
                scheduleRevision &+= 1
            },
            onFindPairsAcrossVolumes: { runner.findPairsAcrossVolumes(source: "panel") },
            onClearAndRecorrelate: { showClearRecorrelateConfirm = true }
        )
        .equatable()
    }

    /// Everything a row renders, as values — derived from the two
    /// snapshots and the sampled flags, never from `records`.
    private func rowFacts(_ cycler: AnalyzeCycler) -> AnalyzeRowFacts {
        let report = coverage.report
        let counts = report.counts(cycler)
        let known = report.coverageKnown(cycler)
        let schedule = live.schedules[cycler] ?? cycler.defaultSchedule
        let liveRule = liveRule(for: cycler)

        let remaining: Int
        let offline: Int
        if cycler == .correlate {
            remaining = report.correlate.unpaired
            offline = report.correlate.offlineCandidates
        } else {
            remaining = counts.remaining
            offline = counts.offline > 0 && counts.remaining == 0 ? counts.offline : 0
        }
        let state = AnalyzeRowStateRule.state(for: cycler, live: liveRule, remaining: remaining,
                                              offlineRemaining: offline, coverageKnown: known,
                                              schedule: schedule)

        let words = Self.coverageWords(for: cycler, counts: counts, report: report)

        var volumes: [AnalyzeRowFacts.VolumeLine] = []
        if cycler.hasVolumeScope, let perVolume = report.byVolume[cycler] {
            volumes = live.volumes.compactMap { v in
                guard let k = perVolume[v.root] else { return nil }
                var text = cycler == .footage ? "\(k.secondary.formatted()) grouped" : k.line
                if !k.sideLine.isEmpty { text += " · \(k.sideLine)" }
                if cycler.isDossierStage {
                    if dossier.state.isVolumeAnalyzing(v.root) { text += " · analyzing" }
                    else if let q = dossier.state.queuePosition(of: v.root) { text += " · in line (#\(q))" }
                    else if dossier.state.parkedVolumePrefixes.contains(v.root) { text += " · waiting for drive" }
                }
                return .init(root: v.root, label: v.label, text: text, isReachable: v.isReachable)
            }
            if let other = perVolume[AnalyzeCoverageCalculator.otherRoot], other.eligible + other.offline > 0 {
                volumes.append(.init(root: AnalyzeCoverageCalculator.otherRoot, label: "Other locations",
                                     text: other.line, isReachable: false))
            }
        }

        return AnalyzeRowFacts(cycler: cycler, state: state, coverageLine: words.line, sideLine: words.side,
                               note: words.note, schedule: schedule, isPaused: liveRule.isPaused,
                               isRunning: liveRule.isRunning, volumes: volumes)
    }

    /// The coverage line, its small side note and the honesty note per
    /// cycler — words only, from the cached counts.
    static func coverageWords(for cycler: AnalyzeCycler, counts: AnalyzeCoverageCounts,
                              report: AnalyzeCoverageReport, now: Date = Date()) -> (line: String, side: String, note: String) {
        switch cycler {
        case .correlate:
            let offline = report.correlate.offlineCandidates
            return (report.correlate.line, offline > 0 ? "\(offline.formatted()) candidates offline" : "", "")
        case .footage:
            var s = "\(counts.secondary.formatted()) files grouped"
            if let d = counts.newestStamp { s += " · last run \(AnalyzeRowStateRule.relative(d, now: now))" }
            return (s, counts.sideLine,
                    "coverage: unknown — only files in a group carry a record of the check; a file in no group is a complete answer with no mark")
        case .ocr:
            return (counts.line, counts.sideLine,
                    "\(counts.secondary.formatted()) with text found · OCR keeps no record of its own — the analysis pass's record stands in")
        case .embeddedDates:
            return (counts.line, counts.sideLine, "a file whose camera wrote no date can never be covered — nothing records that check yet")
        case .dateInference:
            return (counts.line,
                    counts.notApplicable > 0 ? "\(counts.notApplicable.formatted()) have a date you set" : "",
                    "over files with no date of yours; some may never get one")
        default:
            return (counts.line, counts.sideLine, "")
        }
    }

    /// The engine facts for the state rule, per cycler.
    private func liveRule(for cycler: AnalyzeCycler) -> AnalyzeRowStateRule.Live {
        var l = AnalyzeRowStateRule.Live()
        switch cycler {
        case .duplicates:
            l.isRunning = live.isAnalyzingDuplicates
            l.progressText = live.isAnalyzingDuplicates ? live.duplicateStatus : ""
        case .footage:
            l.isRunning = live.footageActive
            l.isPaused = live.footagePaused
            l.progressText = live.footageActive ? live.footageSubtitle : ""
            l.lastAutoRunAt = live.footageLastAutoRunAt
        case .sceneCaptions, .ocr, .transcribe:
            let d = dossier.state
            l.isRunning = d.statusIsActive
            l.isPaused = d.paused || (d.queuePaused && !d.queuedVolumePrefixes.isEmpty)
            l.queueWaitingFromLastSession = d.queuePaused && !d.queuedVolumePrefixes.isEmpty && !d.statusIsActive
            l.parkedVolumes = d.parkedVolumePrefixes.count
            if d.statusIsActive {
                var parts: [String] = []
                if let v = d.currentVolumePrefix { parts.append(VolumeReachability.displayLabel(forPath: v)) }
                if live.dossierTotal > 0 { parts.append("\(live.dossierIndex.formatted()) of \(live.dossierTotal.formatted()) this pass") }
                if !d.queuedVolumePrefixes.isEmpty { parts.append("\(d.queuedVolumePrefixes.count) in line") }
                l.progressText = parts.joined(separator: " · ")
            }
        case .correlate:
            l.isRunning = live.isCorrelating
            l.progressText = live.isCorrelating ? live.correlateStatus : ""
        case .fileSignatures:
            l.isRunning = live.isComputingSignatures
        case .embeddedDates:
            l.isRunning = live.isRefreshingEmbeddedDates
        case .dateInference:
            break   // runs synchronously on the main actor; never "running" between frames
        }
        return l
    }

    // MARK: Scope + Resume (kept from the legacy dashboard, same bindings)

    private var scopeAndResume: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Toggle("Include music and other audio-only files", isOn: includeAudioBinding)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .help("Off (recommended): Scene Captions, OCR and Transcribe focus on files with video. On: audio-only files (music, voice recordings) are transcribed too. Either way, nothing is tagged or removed — set-aside files just wait.")
                        .accessibilityIdentifier("analyze.scope.includeAudio")
                    Spacer()
                    Text("Photos and camera raw files are never analyzed here.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Toggle("Resume Scene Captions, OCR and Transcribe on launch", isOn: $autoResume)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("When on, volumes still in line from the last session start again by themselves a moment after launch. Off: they wait in line until you press Resume.")
                    .accessibilityIdentifier("analyze.resumeOnLaunch")
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
        } label: {
            Text("Analysis Scope").font(.headline)
        }
    }

    /// Two-way binding onto the orchestrator's scope — the ONE mutation
    /// point (updateAnalysisScope does the explicit save); the get side
    /// reads the SNAPSHOT and the set side republishes it synchronously so
    /// the checkbox never visually snaps back.
    private var includeAudioBinding: Binding<Bool> {
        Binding(
            get: { dossier.state.analysisScope.includeAudioOnly },
            set: { on in
                var scope = dossier.state.analysisScope
                scope.includeAudioOnly = on
                orchestrator.updateAnalysisScope(scope)
                orchestrator.publishDashboardSnapshotNow()
                model.analyzeCoverageScope = scope
            }
        )
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Trial: these rows drive the engines as they are today. Find Similar Footage still shows a row in Media File Operations while it runs; the schedule choice is remembered but not yet acted on. The old dashboard is under Window ▸ Analyze Dashboard (legacy).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Live sampling (1 s tick; writes only on change)

    private func sampleLive() {
        var s = AnalyzeLiveSample()
        s.isAnalyzingDuplicates = model.isAnalyzingDuplicates
        s.duplicateStatus = model.duplicateStatus
        s.isCorrelating = model.isCorrelating
        s.correlateStatus = model.correlateStatus
        s.isComputingSignatures = model.isComputingSignatures
        s.isRefreshingEmbeddedDates = model.isRefreshingEmbeddedDates
        if let job = runner.activeFootageJob() {
            s.footageActive = true
            s.footagePaused = job.isPaused
            s.footageSubtitle = job.subtitle
        }
        s.footageLastAutoRunAt = model.archiveAngel.lastFootageAutoRunAt
        s.dossierIndex = orchestrator.liveCurrentIndex
        s.dossierTotal = orchestrator.liveTotal
        for c in AnalyzeCycler.allCases { s.schedules[c] = AnalyzeSchedule.stored(for: c) }
        // O(targets), not O(records): the per-volume disclosure's rows.
        s.volumes = CatalogScanTarget.excludingScratch(model.scanTargets)
            .filter { !$0.isRetired && !$0.searchPath.isEmpty }
            .map { .init(root: VolumeDashboardCalculator.normalizedRoot($0.searchPath),
                         label: VolumeReachability.displayLabel(forPath: $0.searchPath),
                         isReachable: $0.isReachable) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        if s != live { live = s }
        // Keep the coverage math's scope in step with the orchestrator's.
        let scope = dossier.state.analysisScope
        if model.analyzeCoverageScope != scope { model.analyzeCoverageScope = scope }
    }
}

// MARK: - Sampled engine state (Equatable; written once per change)

struct AnalyzeLiveSample: Equatable {
    struct Volume: Equatable { var root: String; var label: String; var isReachable: Bool }
    var isAnalyzingDuplicates = false
    var duplicateStatus = ""
    var isCorrelating = false
    var correlateStatus = ""
    var isComputingSignatures = false
    var isRefreshingEmbeddedDates = false
    var footageActive = false
    var footagePaused = false
    var footageSubtitle = ""
    var footageLastAutoRunAt: Date?
    var dossierIndex = 0
    var dossierTotal = 0
    var schedules: [AnalyzeCycler: AnalyzeSchedule] = [:]
    var volumes: [Volume] = []
}

// MARK: - One row's values

struct AnalyzeRowFacts: Equatable {
    struct VolumeLine: Equatable, Identifiable {
        var root: String
        var label: String
        var text: String
        var isReachable: Bool
        var id: String { root }
    }
    var cycler: AnalyzeCycler
    var state: AnalyzeRowState
    var coverageLine: String
    var sideLine: String
    var note: String
    var schedule: AnalyzeSchedule
    var isPaused: Bool
    var isRunning: Bool
    var volumes: [VolumeLine]
}

// MARK: - Row view (value-only; Equatable so an unchanged row is skipped)

struct AnalyzeCyclerRow: View, Equatable {

    static func == (a: AnalyzeCyclerRow, b: AnalyzeCyclerRow) -> Bool {
        a.facts == b.facts && a.isExpanded == b.isExpanded
    }

    let facts: AnalyzeRowFacts
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    /// nil = all reachable; a root = that volume only.
    let onRunNow: (String?) -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void
    let onSetSchedule: (AnalyzeSchedule) -> Void
    let onFindPairsAcrossVolumes: () -> Void
    let onClearAndRecorrelate: () -> Void

    private var cycler: AnalyzeCycler { facts.cycler }
    private var hasDisclosure: Bool { !facts.volumes.isEmpty || cycler == .correlate }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                if hasDisclosure {
                    Button(action: onToggleExpanded) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("analyze.row.\(cycler.rawValue).disclose")
                } else {
                    Color.clear.frame(width: 12)
                }
                Image(systemName: cycler.systemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(cycler.title)
                            .font(.system(size: 13, weight: .semibold))
                        stateChip
                        if !facts.state.detail.isEmpty {
                            Text(facts.state.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    HStack(spacing: 8) {
                        Text(facts.coverageLine)
                            .font(.system(size: 11, design: .monospaced))
                            .monospacedDigit()
                            .accessibilityIdentifier("analyze.row.\(cycler.rawValue).coverage")
                        if !facts.sideLine.isEmpty {
                            Text(facts.sideLine)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if !facts.note.isEmpty {
                        Text(facts.note)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .help(cycler.help)

                Spacer(minLength: 8)

                controls
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
            .accessibilityIdentifier("analyze.row.\(cycler.rawValue)")

            if isExpanded { disclosure.padding(.leading, 52) }
        }
    }

    private var stateChip: some View {
        Text(facts.state.chipText)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(chipColor.opacity(0.15), in: Capsule())
            .foregroundStyle(chipColor)
            .accessibilityIdentifier("analyze.row.\(cycler.rawValue).state")
    }

    private var chipColor: Color {
        switch facts.state {
        case .current: return .green
        case .cycling: return .blue
        case .paused: return .orange
        case .waitingForDrive: return .orange
        case .manual: return .secondary
        case .auto: return .teal
        case .off: return .gray
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if facts.isRunning || facts.isPaused {
                if facts.isPaused {
                    Button("Resume", action: onResume)
                        .accessibilityIdentifier("analyze.row.\(cycler.rawValue).resume")
                } else {
                    Button("Pause", action: onPause)
                        .disabled(!cycler.isPausable)
                        .help(cycler.isPausable ? "Pause after the current file." : AnalyzeCycler.notPausableHelp)
                        .accessibilityIdentifier("analyze.row.\(cycler.rawValue).pause")
                }
                if cycler.isPausable {
                    Button(action: onStop) { Image(systemName: "stop.fill") }
                        .help("Stop this pass. Results already recorded are kept.")
                        .accessibilityIdentifier("analyze.row.\(cycler.rawValue).stop")
                }
            } else {
                Button("Pause") { }
                    .disabled(true)
                    .help(cycler.isPausable ? "Nothing is running." : AnalyzeCycler.notPausableHelp)
                    .accessibilityIdentifier("analyze.row.\(cycler.rawValue).pause")
            }
            Button("Run now") { onRunNow(nil) }
                .disabled(facts.isRunning)
                .help(facts.isRunning ? "Already running." : "Bring every reachable file up to date for this one now.")
                .accessibilityIdentifier("analyze.row.\(cycler.rawValue).runNow")
            Picker("", selection: Binding(get: { facts.schedule }, set: { onSetSchedule($0) })) {
                ForEach(AnalyzeSchedule.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .labelsHidden()
            .frame(width: 100)
            .help(AnalyzeSchedule.phaseAHelp)
            .accessibilityIdentifier("analyze.row.\(cycler.rawValue).schedule")
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 4) {
            if cycler == .correlate {
                HStack(spacing: 10) {
                    Button("Find A/V Pairs Across Volumes", action: onFindPairsAcrossVolumes)
                        .help("Match Avid MXF video and audio by their material id even when the halves sit on different drives.")
                        .accessibilityIdentifier("analyze.correlate.findPairsAcrossVolumes")
                    Button("Clear & Re-correlate All…", role: .destructive, action: onClearAndRecorrelate)
                        .help("The only from-scratch redo: wipes EVERY pairing, including ones you made by hand, and asks first.")
                        .accessibilityIdentifier("analyze.correlate.clearAndRecorrelate")
                }
                .controlSize(.small)
            }
            ForEach(facts.volumes) { v in
                HStack(spacing: 10) {
                    Image(systemName: v.isReachable ? "externaldrive.fill" : "externaldrive.badge.xmark")
                        .font(.system(size: 11))
                        .foregroundStyle(v.isReachable ? Color.secondary : Color.orange)
                        .frame(width: 16)
                    Text(v.label)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 160, alignment: .leading)
                        .lineLimit(1)
                    Text(v.text)
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if v.root != AnalyzeCoverageCalculator.otherRoot {
                        Button("Run now") { onRunNow(v.root) }
                            .controlSize(.mini)
                            .disabled(!v.isReachable || facts.isRunning)
                            .help(!v.isReachable ? "Drive not connected."
                                  : cycler == .duplicates
                                    ? "Re-check this drive's files for duplicates from scratch — their duplicate marks are cleared and redone. (The catalog-wide Run now only checks new files.)"
                                    : "Bring this drive's files up to date for \(cycler.title).")
                            .accessibilityIdentifier("analyze.row.\(cycler.rawValue).volume.runNow")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
