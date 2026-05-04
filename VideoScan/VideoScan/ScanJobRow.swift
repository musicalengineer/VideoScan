// ScanJobRow.swift
// Per-job row in the Person Finder jobs list — inline pickers, progress ring,
// engine settings popover, compiled output links.

import SwiftUI

// MARK: - Scan Job Row

struct ScanJobRow: View {
    @ObservedObject var job: ScanJob
    @ObservedObject var model: PersonFinderModel
    let isSelected: Bool
    let isExpanded: Bool
    let threshold: Float
    let savedProfiles: [POIProfile]
    let onToggleExpand: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onPause: () -> Void
    let onReset: () -> Void
    let onRemove: () -> Void
    var onPreview: (() -> Void)?

    @State private var showSettingsPopover = false
    @State private var startAlert: String?

    private var isIdle: Bool { job.status.isIdle }
    private var isActive: Bool { job.status.isActive }
    private var isScanning: Bool { job.status == .scanning }

    private var personName: String { job.assignedProfile?.name ?? "—" }
    private var volName: String { (job.searchPath as NSString).lastPathComponent }
    private var engineName: String { job.effectiveEngine.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Always visible: collapsed summary row
            collapsedRow
                .contentShape(Rectangle())
                .onTapGesture { onToggleExpand() }

            // Expanded detail area
            if isExpanded {
                Divider().padding(.vertical, 4)
                expandedDetail
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1.5)
        )
        .alert("Cannot Start", isPresented: Binding(
            get: { startAlert != nil },
            set: { if !$0 { startAlert = nil } }
        )) {
            Button("OK") { startAlert = nil }
        } message: {
            Text(startAlert ?? "")
        }
    }

    // MARK: - Collapsed row (always visible)

    private var collapsedRow: some View {
        HStack(spacing: 8) {
            // Chevron
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 16)

            // Status indicator — only on collapsed row (expanded has its own)
            if !isExpanded {
                if isScanning {
                    SpinningRing(color: statusColor, size: 14)
                } else {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                }
            }

            if isIdle {
                // Idle: show inline pickers right on the collapsed row
                inlinePersonPicker
                inlineVolumePicker
                inlineEnginePicker
            } else if !isExpanded {
                // Active/done: read-only summary text (hidden when expanded — shown in expandedDetail instead)
                let prefix: String = {
                    switch job.status {
                    case .done: return "Done:"
                    case .cancelled: return "Stopped:"
                    case .failed: return "Failed:"
                    case .scanning, .extracting: return "Searching for"
                    case .paused: return "Paused:"
                    default: return ""
                    }
                }()
                Text(prefix)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(personName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)

                if !volName.isEmpty {
                    Text("on")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(volName)
                        .font(.title3.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text("using")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(engineName)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Compact stats on collapsed row
            if job.videosTotal > 0 {
                Text("\(job.videosWithHits)")
                    .font(.system(.body, design: .monospaced).weight(.bold))
                    .foregroundColor(.green)
                Text("/")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Text("\(job.videosScanned)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if job.elapsedSecs > 0 {
                Text(formatElapsed(job.elapsedSecs))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Status badge
            statusBadge

            // Compact action buttons — only when collapsed to avoid duplication
            if !isExpanded {
                if isActive {
                    Button(action: onPause) {
                        Image(systemName: job.status.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                } else if isIdle {
                    Button {
                        if job.assignedProfile == nil {
                            startAlert = "Select a person to search for"
                        } else if job.searchPath.isEmpty {
                            startAlert = "Select a volume to be scanned"
                        } else {
                            onStart()
                        }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    Button(action: onRemove) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .foregroundColor(.red)
                }
            }
        }
    }

    // MARK: - Inline pickers (collapsed row, idle state)

    private var inlinePersonPicker: some View {
        Menu {
            ForEach(savedProfiles) { profile in
                Button {
                    job.assignedProfile = profile
                    if job.assignedEngine == nil,
                       let eng = RecognitionEngine(rawValue: profile.engine) {
                        job.assignedEngine = eng
                    }
                } label: {
                    Label(profile.name, systemImage: job.assignedProfile?.id == profile.id ? "checkmark.circle.fill" : "person.circle")
                }
            }
            if savedProfiles.isEmpty {
                Text("No people added yet")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.fill")
                    .foregroundColor(job.assignedProfile != nil ? .accentColor : .secondary)
                Text(job.assignedProfile?.name ?? "Person…")
                    .fontWeight(job.assignedProfile != nil ? .medium : .regular)
                    .foregroundColor(job.assignedProfile != nil ? .primary : .secondary)
            }
            .font(.body)
        }
        .menuStyle(.borderedButton)
        .fixedSize()
    }

    private var inlineVolumePicker: some View {
        Menu {
            let vols = PersonFinderView.mountedVolumes
            if !vols.isEmpty {
                Section("Mounted Volumes") {
                    ForEach(vols, id: \.path) { vol in
                        Button(vol.lastPathComponent) {
                            job.searchPath = vol.path
                            PersonFinderView.recordRecentPath(vol.path)
                        }
                    }
                }
            }
            let recents = PersonFinderView.recentPaths
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents, id: \.self) { path in
                        Button((path as NSString).lastPathComponent) {
                            job.searchPath = path
                        }
                    }
                }
            }
            Divider()
            Button("Browse…") {
                browsePath()
                if !job.searchPath.isEmpty {
                    PersonFinderView.recordRecentPath(job.searchPath)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .foregroundColor(!job.searchPath.isEmpty ? .accentColor : .secondary)
                Text(!job.searchPath.isEmpty ? (job.searchPath as NSString).lastPathComponent : "Volume…")
                    .fontWeight(!job.searchPath.isEmpty ? .medium : .regular)
                    .foregroundColor(!job.searchPath.isEmpty ? .primary : .secondary)
                    .lineLimit(1)
            }
            .font(.body)
        }
        .menuStyle(.borderedButton)
        .fixedSize()
    }

    private var inlineEnginePicker: some View {
        HStack(spacing: 4) {
            Picker("", selection: Binding(
                get: { job.effectiveEngine },
                set: { job.assignedEngine = $0 }
            )) {
                ForEach(RecognitionEngine.allCases) { eng in
                    Text(eng.rawValue).tag(eng)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Button {
                showSettingsPopover.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.body)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                engineSettingsPopover
            }
        }
    }

    // MARK: - Per-row engine settings popover

    private var engineSettingsPopover: some View {
        let engine = job.effectiveEngine
        return VStack(alignment: .leading, spacing: 12) {
            Text("Settings — \(engine.rawValue)")
                .font(.headline)

            // Common settings
            Group {
                LabeledControl("Match Threshold") {
                    Slider(value: model.settingsBinding.threshold, in: 0.3...0.9, step: 0.05)
                        .frame(width: 140)
                    Text(String(format: "%.2f", model.settings.threshold))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 38)
                }
                LabeledControl("Min Face Confidence") {
                    Slider(value: model.settingsBinding.minFaceConfidence.asDouble, in: 0.3...1.0, step: 0.05)
                        .frame(width: 140)
                    Text(String(format: "%.2f", model.settings.minFaceConfidence))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 38)
                }
                LabeledControl("Frame Step") {
                    TextField("", value: model.settingsBinding.frameStep, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 54)
                    Text("frames")
                }
                LabeledControl("Min Presence") {
                    TextField("", value: model.settingsBinding.minPresenceSecs, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 64)
                    Text("sec")
                }
            }

            Divider()

            Toggle("Primary face only", isOn: model.settingsBinding.requirePrimary)
            Toggle("Skip background faces", isOn: model.settingsBinding.largestFaceOnly)

            Divider()

            // Engine-specific settings
            if engine == .dlib || engine == .hybrid {
                LabeledControl("Python Path") {
                    TextField("", text: model.settingsBinding.pythonPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                LabeledControl("Recognition Script") {
                    TextField("", text: model.settingsBinding.recognitionScript)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                if engine == .dlib {
                    HStack(spacing: 4) {
                        Image(systemName: model.settings.dlibReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(model.settings.dlibReady ? .green : .red)
                        Text(model.settings.dlibReady ? "dlib ready" : "dlib not configured")
                            .font(.callout)
                    }
                }
            }

            Divider()

            // Compile options
            Toggle("Compile to one video", isOn: model.settingsBinding.concatOutput)
                .disabled(model.settings.decadeChapters)
            Toggle("Decade chapter video", isOn: model.settingsBinding.decadeChapters)

            Divider()

            LabeledControl("Parallel Jobs") {
                TextField("", value: model.settingsBinding.concurrency, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 54)
                Stepper("", value: model.settingsBinding.concurrency, in: 1...32)
                    .labelsHidden()
            }

            Text("Settings apply when scan starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: - Status badge

    @ViewBuilder
    private var statusBadge: some View {
        switch job.status {
        case .done:
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundColor(.green)
        case .scanning:
            Text("Scanning")
                .font(.body.weight(.semibold))
                .foregroundColor(.blue)
        case .paused:
            Text("Paused")
                .font(.body.weight(.semibold))
                .foregroundColor(.yellow)
        case .extracting:
            Text("Extracting")
                .font(.body.weight(.semibold))
                .foregroundColor(.orange)
        case .failed:
            Text("Failed")
                .font(.body.weight(.semibold))
                .foregroundColor(.red)
        case .cancelled:
            Text("Stopped")
                .font(.body.weight(.semibold))
                .foregroundColor(.secondary)
        default:
            EmptyView()
        }
    }

    // MARK: - Expanded detail

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status summary line for non-idle jobs
            if !isIdle {
                HStack(spacing: 10) {
                    if isScanning {
                        SpinningRing(color: statusColor, size: 22)
                    }

                    let prefix: String = {
                        switch job.status {
                        case .done: return "Done:"
                        case .cancelled: return "Stopped:"
                        case .failed: return "Failed:"
                        case .scanning, .extracting: return "Searching for"
                        case .paused: return "Paused:"
                        default: return ""
                        }
                    }()
                    Text(prefix)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(personName)
                        .font(.title2.weight(.bold))
                    if !volName.isEmpty {
                        Text("on")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(volName)
                            .font(.title2.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text("using")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(engineName)
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            // Stats + full action buttons
            HStack(spacing: 10) {
                if job.videosTotal > 0 {
                    Label("\(job.videosWithHits) matches", systemImage: "person.fill.checkmark")
                        .font(.body.weight(.medium))
                        .foregroundColor(.green)
                    Text("\(job.videosScanned) / \(job.videosTotal) videos")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                if job.elapsedSecs > 0 {
                    Text(formatElapsed(job.elapsedSecs))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer()

                expandedActionButtons
            }

            // Progress ring
            if job.videosTotal > 0 {
                ScanRingChart(
                    total: job.videosTotal,
                    scanned: job.videosScanned,
                    hits: job.videosWithHits,
                    elapsedSecs: job.elapsedSecs,
                    currentFile: isActive ? job.currentFile : "",
                    bestDist: job.bestDist,
                    threshold: threshold
                )
            } else if isActive {
                HStack(spacing: 8) {
                    ProgressView().progressViewStyle(.circular).scaleEffect(0.7)
                    Text(job.status.label).font(.callout).foregroundColor(.secondary)
                }
            }

            // Compiled outputs
            if !job.compiledVideoPaths.isEmpty {
                compiledOutputsView
            }
        }
    }

    // MARK: - Expanded action buttons (full labels)

    @ViewBuilder
    private var expandedActionButtons: some View {
        if isActive {
            Button(action: onPause) {
                Label(job.status.isPaused ? "Resume" : "Pause",
                      systemImage: job.status.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Button(action: onStop) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            if job.status == .scanning, let onPreview {
                Button { onPreview() } label: {
                    Label("Preview", systemImage: "eye.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        } else {
            Button {
                if job.assignedProfile == nil {
                    startAlert = "Select a person to search for"
                } else if job.searchPath.isEmpty {
                    startAlert = "Select a volume to be scanned"
                } else {
                    onStart()
                }
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            if !isIdle {
                Button(action: onReset) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            Button(action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .foregroundColor(.red)
        }
    }

    // MARK: - Compiled outputs

    private var compiledOutputsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "film.stack")
                    .foregroundColor(.accentColor)
                Text("\(job.compiledVideoPaths.count) compilation\(job.compiledVideoPaths.count == 1 ? "" : "s")")
                    .font(.system(.callout, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
            ForEach(job.compiledVideoPaths) { out in
                HStack(spacing: 8) {
                    Text((out.path as NSString).lastPathComponent)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(out.clipCount) clip\(out.clipCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(pfFormatDuration(out.durationSecs))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(pfFormatBytes(out.bytesOnDisk))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Reveal") {
                        NSWorkspace.shared.selectFile(out.path, inFileViewerRootedAtPath: "")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Open") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: out.path))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(6)
    }

    var statusColor: Color {
        switch job.status {
        case .idle:       return .secondary
        case .loading:    return .yellow
        case .scanning:   return .blue
        case .paused:     return .yellow
        case .extracting: return .orange
        case .compiling:  return .purple
        case .done:       return .green
        case .cancelled:  return .secondary
        case .failed:     return .red
        }
    }

    func browsePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a volume or folder to scan"
        panel.prompt = "Select"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                self.job.searchPath = url.path
                PersonFinderView.recordRecentPath(url.path)
            }
        }
    }

}

// MARK: - Helper Views

struct LabeledControl<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            HStack(spacing: 4) { content() }
        }
    }
}

struct RecognitionEnginePanel: View {
    let engine: RecognitionEngine
    @Binding var pythonPath: String
    @Binding var recognitionScript: String
    let dlibReady: Bool
    let dlibReadyForHybrid: Bool
    let browsePython: () -> Void
    let browseScript: () -> Void

    private var statusText: String {
        switch engine {
        case .vision:
            return "Built-in module is ready"
        case .arcface:
            return "ArcFace CoreML — local face identity model on ANE"
        case .dlib:
            return dlibReady ? "Python recognizer is ready" : "Set Python and Script paths to enable this module"
        case .hybrid:
            return dlibReadyForHybrid ? "Vision will fall back to dlib when needed" : "Running in Vision-only mode until dlib paths are configured"
        }
    }

    private var statusSymbol: String {
        switch engine {
        case .vision:
            return "checkmark.circle"
        case .arcface:
            return "brain"
        case .dlib:
            return dlibReady ? "checkmark.circle" : "exclamationmark.triangle"
        case .hybrid:
            return dlibReadyForHybrid ? "arrow.triangle.branch" : "info.circle"
        }
    }

    private var statusColor: Color {
        switch engine {
        case .vision:
            return .green
        case .arcface:
            return .green
        case .dlib:
            return dlibReady ? .green : .orange
        case .hybrid:
            return dlibReadyForHybrid ? .green : .secondary
        }
    }

    private var showsDlibConfig: Bool {
        engine == .dlib || engine == .hybrid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: engine.symbolName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(engine.title)
                            .font(.headline)
                        Text(engine.shortLabel.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    Text(engine.subtitle)
                        .foregroundStyle(.secondary)
                    Label(statusText, systemImage: statusSymbol)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
                Spacer(minLength: 0)
            }

            if showsDlibConfig {
                HStack(alignment: .top, spacing: 24) {
                    LabeledControl("Python") {
                        TextField("venv/bin/python…", text: $pythonPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 280)
                        Button("…") { browsePython() }
                            .controlSize(.small)
                    }
                    LabeledControl("Script") {
                        TextField("face_recognize.py…", text: $recognitionScript)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 280)
                        Button("…") { browseScript() }
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
            }

            Text("Recognition engines are modular. Add a new case to the registry and implement the shared scan contract to plug another backend into this selector.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Live scans use the settings captured when that scan starts. Changing modules while a job is paused or running does not switch the active engine mid-video.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if showsDlibConfig {
                Text("Heavy scans are auto-limited based on free RAM to avoid runaway memory use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Scan Ring Chart

struct ScanRingChart: View {
    let total: Int
    let scanned: Int
    let hits: Int
    let elapsedSecs: Double
    let currentFile: String
    let bestDist: Float
    let threshold: Float

    private var scannedFrac: Double { total > 0 ? min(1, Double(scanned) / Double(total)) : 0 }
    private var hitsFrac: Double { total > 0 ? min(1, Double(hits)    / Double(total)) : 0 }
    private var vps: Double? { elapsedSecs > 2 && scanned > 2 ? Double(scanned) / elapsedSecs : nil }

    // Colour the best-dist reading relative to the active threshold
    private var distColor: Color {
        guard bestDist < .greatestFiniteMagnitude else { return .secondary }
        if bestDist <= threshold { return .green }   // within threshold — a hit
        if bestDist <= threshold + 0.10 { return .orange }  // close — might just need threshold nudge
        return .secondary
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Ring
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: scannedFrac)
                    .stroke(Color.blue.opacity(0.45),
                            style: StrokeStyle(lineWidth: 10, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: scannedFrac)
                Circle()
                    .trim(from: 0, to: hitsFrac)
                    .stroke(Color.green,
                            style: StrokeStyle(lineWidth: 10, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: hitsFrac)
                VStack(spacing: 0) {
                    Text("\(scanned)")
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                    Text("/ \(total)")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)

            // Stats + best dist
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("\(hits) match\(hits == 1 ? "" : "es")")
                        .font(.callout.weight(.semibold)).foregroundColor(.green)
                }
                HStack(spacing: 5) {
                    Circle().fill(Color.blue.opacity(0.5)).frame(width: 7, height: 7)
                    Text("\(scanned) scanned")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Circle().fill(Color.secondary.opacity(0.25)).frame(width: 7, height: 7)
                    Text("\(max(0, total - scanned)) remaining")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let v = vps {
                    Text(String(format: "%.1f vid/s", v))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Divider().frame(height: 56)

            // Best distance — the key calibration number
            VStack(alignment: .center, spacing: 2) {
                Text("BEST DIST")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1)
                if bestDist < .greatestFiniteMagnitude {
                    Text(String(format: "%.3f", bestDist))
                        .font(.system(.title2, design: .monospaced).weight(.bold))
                        .foregroundColor(distColor)
                        .animation(.easeInOut(duration: 0.3), value: bestDist)
                } else {
                    Text("—")
                        .font(.system(.title2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("thresh \(String(format: "%.2f", threshold))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                if !currentFile.isEmpty {
                    Text((currentFile as NSString).lastPathComponent)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 160, alignment: .center)
                }
            }
            .frame(minWidth: 90)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Binding helpers

extension Binding where Value == Float {
    var asDouble: Binding<Double> {
        Binding<Double>(
            get: { Double(wrappedValue) },
            set: { wrappedValue = Float($0) }
        )
    }
}
