// RealtimeContentAnalysisWindow.swift — "what is the content analyzer doing
// right now" (Rick 2026-11-05 evening), the Realtime Catalog Scan window's
// sibling: a big phase header with Pause/Stop, the IN → WORK → OUT strip for
// the files in the pipeline, the machine's CPU / GPU / memory / disk with
// their sources, the batch's done tiles, VideoScan Background's own numbers,
// and the latest results — each clickable into the file's dossier.
//
// Truth rules carried here:
//   * nothing animates unless a lane exists (`inApp.isWorking`): the dot
//     pulses on real work only; idle says idle;
//   * a counter the kernel would not give shows "—"; its tooltip says why;
//     every machine tile's tooltip names its source;
//   * the helper pane is grey and blue only (DECISIONS 2026-11-03: machine
//     inference is never yellow); `era.none` reads "no usable era", never an era;
//   * no O(records) work: the view reads one small value (RealtimeAnalysisState)
//     published at ≤ 2 Hz; a file's dossier opens through the one door.
//
// (For Rick: the view is a pure function of `store.state`; the controller is
// the same NSWindow shape as CatalogScanWindowController.)

import AppKit
import SwiftUI
import VideoScanCore

// MARK: - Content

struct RealtimeContentAnalysisContent: View {
    @ObservedObject var store: RealtimeAnalysisStore
    /// The row whose dossier is open (one at a time; a second click closes it).
    @State private var openDossier: UUID?

    private var state: RealtimeAnalysisState { store.state }
    private var inApp: RealtimeAnalysisState.InApp { state.inApp }

    private var phaseColor: Color {
        switch inApp.phase {
        case .idle: return .gray
        case .analyzing: return inApp.isWorking ? .cyan : .blue
        case .paused: return .blue
        case .stopping: return .orange
        case .finished: return .green
        }
    }

    var body: some View {
        ScrollView {
            panes
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 560, idealHeight: 760)
        .background(Color(NSColor.windowBackgroundColor))
        .accessibilityIdentifier("realtime.ca.window")
    }

    /// The six panes without the scroll view (ImageRenderer draws a ScrollView
    /// blank; the mockup test renders this).
    var panes: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            pipelinePane
            machinePane
            donePane
            helperPane
            resultsPane
        }
        .padding(14)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: Header

    private var phaseLine: String {
        switch inApp.phase {
        case .idle: return "Idle — no captions or transcripts running"
        case .finished: return "Finished — \(inApp.captioned) analyzed · \(inApp.skipped) skipped · \(inApp.failed) failed"
        case .stopping: return "Stopping — the file in flight banks what it has"
        case .analyzing, .paused:
            var parts: [String] = []
            if inApp.total > 0 { parts.append("\(inApp.currentIndex) / \(inApp.total)") }
            parts.append(RealtimeAnalysisState.secondsPerFileWords(inApp.secondsPerFile, over: inApp.timedCount))
            parts.append(RealtimeAnalysisState.etaWords(inApp.etaSeconds))
            return parts.joined(separator: " · ")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(phaseColor.opacity(0.15)).frame(width: 38, height: 38)
                Circle()
                    .fill(phaseColor)
                    .frame(width: 14, height: 14)
                    .shadow(color: phaseColor.opacity(0.6), radius: inApp.isWorking ? 8 : 0)
                    .scaleEffect(inApp.isWorking ? 1.1 : 1.0)
                    .animation(inApp.isWorking
                               ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                               : .default, value: inApp.isWorking)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(inApp.phase.rawValue.uppercased())
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(phaseColor)
                Text(phaseLine)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.secondary)
                if let prefix = inApp.volumePrefix, inApp.phase == .analyzing || inApp.phase == .paused {
                    Text(VolumeReachability.displayLabel(forPath: prefix))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    if inApp.phase == .paused { store.resume() } else { store.pause() }
                } label: {
                    Label(inApp.phase == .paused ? "Resume" : "Pause",
                          systemImage: inApp.phase == .paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!(inApp.phase == .analyzing || inApp.phase == .paused))
                .help("Pause finishes the file in flight, then waits. Same control as Content Analysis ▸ Scene Captions.")
                .accessibilityIdentifier("realtime.ca.pause")

                Button { store.stopAnalysis() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!(inApp.phase == .analyzing || inApp.phase == .paused))
                .help("Stop this pass. Results already banked are kept.")
                .accessibilityIdentifier("realtime.ca.stop")
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: IN → WORK → OUT

    private var pipelinePane: some View {
        RealtimePane {
            if inApp.lanes.isEmpty {
                HStack {
                    Image(systemName: "tray").foregroundColor(.secondary)
                    Text(inApp.phase == .analyzing ? "Between files — the next one is being planned" : "Nothing in the pipeline")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.vertical, 4)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(inApp.lanes) { lane in
                            RealtimeLaneRow(lane: lane, now: context.date)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 14) {
                Label("In", systemImage: "arrow.right.doc.on.clipboard")
                Image(systemName: "arrow.right").foregroundColor(.secondary)
                Label("Work", systemImage: "cpu")
                Image(systemName: "arrow.right").foregroundColor(.secondary)
                Label("Out", systemImage: "text.quote")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.cyan)
        }
    }

    // MARK: Machine

    private var machinePane: some View {
        RealtimePane {
            HStack(spacing: 8) {
                machineTile(icon: "cpu", label: "CPU", reading: state.machine.cpu, max: 100)
                machineTile(icon: "memorychip", label: "GPU", reading: state.machine.gpu, max: 100)
                machineTile(icon: "memorychip.fill", label: "Memory",
                            reading: state.machine.memory, max: max(1, state.machine.memoryTotalGB),
                            sub: state.machine.memoryTotalGB > 0 ? String(format: "of %.0f GB", state.machine.memoryTotalGB) : nil)
                machineTile(icon: "internaldrive", label: "Disk read", reading: state.machine.diskRead, max: nil)
            }
        } label: {
            Label(machineLabel, systemImage: "gauge.with.dots.needle.67percent")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.purple)
        }
    }

    private var machineLabel: String {
        guard let at = state.machine.sampledAt else { return "This Mac — not sampled yet" }
        return "This Mac — sampled \(RealtimeContentAnalysisContent.clock.string(from: at))"
    }

    private func machineTile(icon: String, label: String, reading: RealtimeAnalysisState.Reading,
                             max: Double?, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 11)).foregroundColor(.purple)
                Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            }
            Text(reading.words)
                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(reading.value == nil ? .secondary : .purple)
            CounterSparkline(values: reading.history, max: max)
                .frame(height: 22)
            Text(reading.problem ?? sub ?? "last \(reading.history.count) sample\(reading.history.count == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .help(reading.tooltip)
    }

    // MARK: Done

    private var donePane: some View {
        RealtimePane {
            HStack(spacing: 8) {
                // captions = files whose captions banked (not every completion, Codex F2);
                // "no speech" is its own grey tile; "transcript failed" counts thrown errors only (F3).
                countTile("captions", inApp.captioned, .green, "text.below.photo")
                countTile("transcripts", inApp.transcribed, .green, "waveform")
                countTile("no speech", inApp.noSpeech, .secondary, "speaker.zzz")
                countTile("transcript failed", inApp.transcriptFailures, inApp.transcriptFailures > 0 ? .orange : .secondary, "waveform.slash")
                countTile("failed", inApp.failed, inApp.failed > 0 ? .red : .secondary, "xmark.octagon")
                countTile("skipped", inApp.skipped, .secondary, "forward.end")
            }
        } label: {
            Label("Done this pass", systemImage: "checkmark.seal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.green)
        }
    }

    private func countTile(_ label: String, _ count: Int, _ color: Color, _ icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 15)).foregroundColor(color)
            Text("\(count)")
                .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(count > 0 ? color : .secondary.opacity(0.5))
            Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(color.opacity(count > 0 ? 0.08 : 0.0))
        .cornerRadius(6)
    }

    // MARK: VideoScan Background (grey and blue only)

    private var helper: RealtimeAnalysisState.Helper { state.helper }

    private var helperPane: some View {
        RealtimePane {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(helper.era?.stateWords == "running" ? Color.blue : Color.gray)
                        .frame(width: 9, height: 9)
                    // One honest phrase (the run's own N of M; the plan only when no run is on).
                    Text(helper.progressWords)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                // The journal's counts, or "—" with the reason when the read failed (Codex F5).
                let tally = helper.tally
                HStack(spacing: 8) {
                    helperTile("era found", tally.available ? tally.eraFound : nil, problem: tally.readProblem)
                    helperTile("no usable era", tally.available ? tally.eraNone : nil, problem: tally.readProblem)
                    helperTile("gave up", tally.available ? tally.gaveUp : nil, problem: tally.readProblem)
                    helperTile("trying", helper.triesInProgress, problem: helper.triesProblem)
                }
                Text(helperJournalWords)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                if !helper.tally.latest.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(helper.tally.latest) { o in
                            HStack(spacing: 6) {
                                Text(RealtimeContentAnalysisContent.clock.string(from: Date(timeIntervalSince1970: TimeInterval(o.at))))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text(o.words)
                                    .font(.system(size: 11))
                                    .foregroundColor(o.kind == .eraFound ? .blue : .secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                }
            }
        } label: {
            Label("VideoScan Background — era (\(helper.modelShortName.isEmpty ? "helper" : helper.modelShortName))",
                  systemImage: "moon.zzz")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.blue)
        }
    }

    private var helperJournalWords: String {
        var parts: [String] = []
        if let problem = helper.tally.readProblem {
            parts.append("counts unavailable — " + problem)
        } else if let file = helper.tally.file {
            parts.append("journal \(file): \(helper.tally.lines.formatted()) lines"
                         + (helper.tally.other > 0 ? " (\(helper.tally.other.formatted()) supporting lines: year-range windows, on-screen dates)" : "")
                         + (helper.tally.unreadable > 0 ? " · \(helper.tally.unreadable) unreadable" : "")
                         + (helper.tally.torn ? " · torn tail (a write in flight)" : ""))
        }
        if let words = helper.journalWords { parts.append(words) }
        return parts.isEmpty ? "journal not read yet" : parts.joined(separator: " — ")
    }

    private func helperTile(_ label: String, _ count: Int?, problem: String? = nil) -> some View {
        VStack(spacing: 3) {
            Text(count.map { "\($0)" } ?? "—")
                .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor((count ?? 0) > 0 ? .blue : .secondary.opacity(0.6))
            Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.blue.opacity((count ?? 0) > 0 ? 0.06 : 0.0))
        .cornerRadius(6)
        .help(problem ?? helperTileHelp(label))
    }

    private func helperTileHelp(_ label: String) -> String {
        switch label {
        case "trying": return "Files with tries and no verdict yet: the attempts log minus every file whose verdict already landed in the catalog or the journal (the Results sheet's rule)"
        default: return "Counted from the helper's journal day file (read-only); era.none is never shown as an era"
        }
    }

    // MARK: Latest results (click → the file's dossier)

    private var resultsPane: some View {
        RealtimePane {
            if inApp.recent.isEmpty {
                Text("No file has finished since the app started.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(inApp.recent) { output in
                        RealtimeOutputRow(output: output, isOpen: openDossier == output.id, canOpen: store.dossiers != nil) {
                            openDossier = openDossier == output.id ? nil : output.id
                        }
                        if openDossier == output.id, let loader = store.dossiers {
                            FileDossierView(fileID: output.recordID, loader: loader)
                                .equatable()
                                .padding(.leading, 22)
                                .padding(.bottom, 4)
                        }
                    }
                }
            }
        } label: {
            Label("Latest results (\(inApp.recent.count)) — click one for its dossier", systemImage: "list.bullet.rectangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.cyan)
        }
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - Pane (pure SwiftUI: GroupBox is AppKit-backed and ImageRenderer draws it blank)

struct RealtimePane<Label: View, Content: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            label()
            content()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
                .cornerRadius(8)
        }
    }
}

// MARK: - One lane: IN → WORK → OUT

struct RealtimeLaneRow: View {
    let lane: RealtimeAnalysisState.Lane
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // IN
            HStack(spacing: 5) {
                Image(systemName: lane.isVideoOnly ? "video" : "film")
                    .foregroundColor(.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text(lane.filename)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.cyan)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    let clip = RealtimeAnalysisState.clipWords(lane.clipSeconds)
                    if !clip.isEmpty {
                        Text(clip).font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right").foregroundColor(.secondary).padding(.top, 2)

            // WORK
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: lane.isTranscribing ? "waveform" : "photo.stack")
                        .foregroundColor(.cyan)
                    Text(lane.stage)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.cyan)
                    Text(lane.verb)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    if lane.framesPlanned > 0 && !lane.isTranscribing {
                        Text("\(lane.framesPlanned) frames to rip").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    if lane.hasCaptions {
                        // In memory until applyDossier at the lane's end (Codex F1): never "banked" here.
                        Label("scenes extracted", systemImage: "checkmark").font(.system(size: 10)).foregroundColor(.green)
                    }
                    Text(RealtimeAnalysisState.elapsedWords(since: lane.startedAt, now: now))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right").foregroundColor(.secondary).padding(.top, 2)

            // OUT — nothing until the file banks (the results pane shows it then)
            Text(lane.outWords)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - One finished file

struct RealtimeOutputRow: View {
    let output: RealtimeAnalysisState.Output
    let isOpen: Bool
    let canOpen: Bool
    let onToggle: () -> Void

    private var seconds: String {
        var parts: [String] = []
        if let v = output.vlmSeconds { parts.append(String(format: "VLM %.1fs", v)) }
        if let w = output.whisperSeconds { parts.append(String(format: "Whisper %.1fs", w)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(canOpen ? .secondary : .clear)
                Text(RealtimeContentAnalysisContent.clock.string(from: output.syncedAt))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(output.filename)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                indicator(output.hasCaptions, "text.below.photo", output.hasCaptions ? "\(output.sceneCount) scenes" : "no captions")
                indicator(output.hasTranscript, output.isVideoOnly ? "speaker.slash" : "waveform", output.transcriptWords)
                if let bank = output.bankWords {
                    Label(bank, systemImage: "exclamationmark.triangle").font(.system(size: 10)).foregroundColor(.orange)
                }
                Spacer()
                Text(seconds).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            }
            if let caption = output.firstCaption {
                Text("“\(caption)”")
                    .font(.system(size: 11))
                    .italic()
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 22)
            }
            if let excerpt = output.transcriptExcerpt {
                Text("♪ \(excerpt)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 22)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if canOpen { onToggle() } }
        .help(canOpen ? "Click for this file's dossier (what the catalog stores about it)" : "")
    }

    private func indicator(_ ok: Bool, _ icon: String, _ words: String) -> some View {
        Label(words, systemImage: icon)
            .font(.system(size: 10))
            .foregroundColor(ok ? .green : .secondary)
    }
}

// MARK: - Sparkline (plain values, bounded history)

struct CounterSparkline: View {
    let values: [Double]
    /// The top of the chart; nil = the series' own maximum.
    let max: Double?

    var body: some View {
        GeometryReader { geo in
            let top = Swift.max(self.max ?? (values.max() ?? 1), 0.000_1)
            Path { p in
                guard values.count > 1 else { return }
                let step = geo.size.width / CGFloat(values.count - 1)
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * step
                    let y = geo.size.height * (1 - CGFloat(Swift.min(v, top) / top))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.purple.opacity(0.8), lineWidth: 1.5)
        }
    }
}

// MARK: - Window controller

@MainActor
final class RealtimeContentAnalysisWindowController {
    static let shared = RealtimeContentAnalysisWindowController()
    nonisolated static let windowTitle = "Realtime Content Analysis"

    private var window: NSWindow?
    private var store: RealtimeAnalysisStore?
    private var closeObserver: NSObjectProtocol?

    /// The one door (the Content Analysis panel's Realtime… and an Analyze
    /// row's context menu both come here). `source` is logged once.
    func show(model: VideoScanModel, orchestrator: CaptionOrchestrator, source: String) {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }
        close()
        let store = RealtimeAnalysisStore.production(model: model, orchestrator: orchestrator)
        self.store = store
        let hosting = NSHostingView(rootView: RealtimeContentAnalysisContent(store: store))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        // AppKit would double-release on close otherwise (CatalogScanWindowController).
        w.isReleasedWhenClosed = false
        w.title = Self.windowTitle
        w.contentView = hosting
        w.setFrameAutosaveName("RealtimeContentAnalysisV1")
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        store.sources.note("shown from \(source)")
        store.start()
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.store?.stop()
                self.store = nil
                self.window = nil
                if let obs = self.closeObserver {
                    NotificationCenter.default.removeObserver(obs)
                    self.closeObserver = nil
                }
            }
        }
    }

    func close() {
        if let obs = closeObserver {
            NotificationCenter.default.removeObserver(obs)
            closeObserver = nil
        }
        store?.stop()
        store = nil
        window?.close()
        window = nil
    }
}
