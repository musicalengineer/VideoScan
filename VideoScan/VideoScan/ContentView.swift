import SwiftUI
import Combine
import AVKit

// MARK: - Root (Tab switcher)

struct ContentView: View {
    @EnvironmentObject var model: VideoScanModel

    var body: some View {
        TabView {
            CatalogView()
                .tabItem { Label("Video Catalog", systemImage: "film.stack") }
            PersonFinderView()
                .tabItem { Label("Person Finder", systemImage: "person.crop.rectangle.stack") }
            SettingsTabView(
                settings: Binding(
                    get: { model.perfSettings },
                    set: { model.perfSettings = $0 }
                ),
                totalRAMGB: Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
            )
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

// MARK: - Catalog Tab

struct CatalogView: View {
    @EnvironmentObject var model: VideoScanModel
    @State private var selectedIDs: Set<UUID> = []
    @State private var showCombineSheet = false
    @State private var showDashboard = false
    @State private var sortOrder = [KeyPathComparator(\VideoRecord.filename)]
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {

            // MARK: Scan Targets Pane
            scanTargetsPane

            Divider()

            // MARK: Toolbar (post-scan actions)
            CatalogToolbar(
                isScanning: model.isScanning,
                isCombining: model.isCombining,
                hasRecords: !model.records.isEmpty,
                hasCorrelatedPairs: !model.correlatedPairs.isEmpty,
                outputCSVPath: model.outputCSVPath,
                selectedIDs: selectedIDs,
                showCombineSheet: $showCombineSheet,
                showDashboard: $showDashboard,
                searchText: $searchText,
                cacheCount: model.cacheCount,
                onStopCombine: { model.stopCombine() },
                onCorrelateAll: {
                    model.log("\nCorrelating all audio-only and video-only files...")
                    model.correlate()
                },
                onCorrelateSelected: {
                    model.log("\nCorrelating \(selectedIDs.count) selected files...")
                    model.correlate(selectedIDs: selectedIDs)
                },
                onClearResults: { model.clearResults() },
                onClearCache: { _ = model.clearCache() },
                dashboardContent: {
                    if model.isScanning || model.isCombining {
                        CompactDashboard(
                            dashboard: model.dashboard,
                            isScanning: model.isScanning,
                            isCombining: model.isCombining,
                            isExpanded: $showDashboard
                        )
                        .popover(isPresented: $showDashboard, arrowEdge: .bottom) {
                            ExpandedDashboard(
                                dashboard: model.dashboard,
                                isScanning: model.isScanning,
                                isCombining: model.isCombining
                            )
                        }
                    }
                }
            )

            Divider()

            // MARK: Split — Table top, Preview bottom
            CatalogContent(
                records: model.records,
                selectedIDs: $selectedIDs,
                sortOrder: $sortOrder,
                searchText: searchText,
                previewImage: model.previewImage,
                previewFilename: model.previewFilename,
                onSort: { model.records.sort(using: $0) },
                onSelect: { id in
                    if let rec = model.records.first(where: { $0.id == id }),
                       rec.streamType == .videoOnly || rec.streamType == .videoAndAudio {
                        model.generateThumbnail(for: rec)
                    } else {
                        model.previewImage = nil
                        model.previewFilename = ""
                    }
                },
                onClearPreview: {
                    model.previewImage = nil
                    model.previewFilename = ""
                }
            )
        }
        .sheet(isPresented: $showCombineSheet) {
            CombineSheet(selectedIDs: selectedIDs)
        }
    }

    // MARK: - Scan Targets Pane (matches PersonFinder's jobsSection pattern)

    private var scanTargetsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.title3).foregroundColor(.secondary)
                Text("Scan Targets")
                    .font(.title3.weight(.semibold))
                Spacer()

                Button(action: { model.addScanTarget() }) {
                    Label("Add Volumes…", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: { model.startAllTargets() }) {
                    Label("Start All", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.scanTargets.isEmpty || model.scanTargets.allSatisfy { $0.status.isActive })

                Button(action: {
                    if model.hasPausedTargets { model.resumeAllTargets() }
                    else { model.pauseAllTargets() }
                }) {
                    Label(model.hasPausedTargets ? "Resume All" : "Pause All",
                          systemImage: model.hasPausedTargets ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!model.hasActiveTargets && !model.hasPausedTargets)

                Button(action: { model.stopAllTargets() }) {
                    Label("Stop All", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!model.hasActiveTargets)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if model.scanTargets.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "externaldrive.badge.plus")
                        .font(.largeTitle).foregroundColor(.secondary)
                    Text("No scan targets yet")
                        .font(.headline).foregroundColor(.secondary)
                    Text("Click \"Add Volumes…\" to add a drive or folder to scan.")
                        .font(.callout).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.scanTargets) { target in
                            CatalogTargetRow(
                                target: target,
                                onStart: { model.startTarget(target) },
                                onStop: { model.stopTarget(target) },
                                onPause: { model.togglePauseTarget(target) },
                                onRemove: { model.removeScanTarget(target) }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .frame(minHeight: 60, maxHeight: 220)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Catalog Target Row (per-path controls, matches PersonFinder's ScanJobRow)

private struct CatalogTargetRow: View {
    @Bindable var target: CatalogScanTarget
    let onStart: () -> Void
    let onStop: () -> Void
    let onPause: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Status dot
            Circle()
                .fill(target.status.color)
                .frame(width: 12, height: 12)
                .shadow(color: target.status.color.opacity(0.5), radius: 3)

            // Path (editable when idle)
            if target.status.isIdle {
                HStack(spacing: 8) {
                    TextField("Volume or folder path…", text: $target.searchPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Browse…") { browsePath() }
                        .controlSize(.regular)
                }
            } else {
                Text(target.searchPath)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Progress stats
            if target.status == .discovering {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Discovering…")
                        .font(.callout).foregroundColor(.secondary)
                }
            } else if target.filesFound > 0 {
                Text("\(target.filesScanned) / \(target.filesFound) files")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if target.elapsedSecs > 0 {
                Text(formatElapsed(target.elapsedSecs))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Action buttons
            if target.status.isActive {
                Button(action: onPause) {
                    Label(target.status.isPaused ? "Resume" : "Pause",
                          systemImage: target.status.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button(action: onStop) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            } else {
                Button(action: onStart) {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(target.searchPath.isEmpty)

                if target.status == .complete || target.status == .stopped || target.status == .error {
                    Button(action: { target.reset() }) {
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
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private func browsePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a volume or folder to scan"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            target.searchPath = url.path
        }
    }

    private func formatElapsed(_ secs: Double) -> String {
        let m = Int(secs) / 60
        let s = Int(secs) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Toolbar (post-scan actions: correlate, combine, search, export)

private struct CatalogToolbar<Dashboard: View>: View {
    let isScanning: Bool
    let isCombining: Bool
    let hasRecords: Bool
    let hasCorrelatedPairs: Bool
    let outputCSVPath: String
    let selectedIDs: Set<UUID>
    @Binding var showCombineSheet: Bool
    @Binding var showDashboard: Bool
    @Binding var searchText: String
    let cacheCount: Int
    let onStopCombine: () -> Void
    let onCorrelateAll: () -> Void
    let onCorrelateSelected: () -> Void
    let onClearResults: () -> Void
    let onClearCache: () -> Void
    @ViewBuilder let dashboardContent: () -> Dashboard

    private var canCombine: Bool {
        guard !isScanning && !isCombining else { return false }
        return hasCorrelatedPairs
    }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Clear Results") { onClearResults() }
                    .disabled(!hasRecords)
                Divider()
                Button("Clear Cache (\(cacheCount) entries)") { onClearCache() }
                    .disabled(cacheCount == 0)
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 80)
            .disabled(isScanning)

            Divider().frame(height: 22)

            Menu {
                Button("Correlate All", action: onCorrelateAll)
                Button("Correlate Selected", action: onCorrelateSelected)
                    .disabled(selectedIDs.isEmpty)
            } label: {
                Label("Correlate", systemImage: "arrow.triangle.2.circlepath")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 110)
            .disabled(isScanning || !hasRecords)

            Button(action: { showCombineSheet = true }) {
                Label("Combine", systemImage: "rectangle.stack.badge.plus")
            }
            .buttonStyle(.bordered)
            .disabled(!canCombine && !isCombining)

            if isCombining {
                Button(action: onStopCombine) {
                    Label("Stop Combine", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            if !outputCSVPath.isEmpty {
                Button(action: {
                    NSWorkspace.shared.selectFile(outputCSVPath, inFileViewerRootedAtPath: "")
                }) {
                    Label("Show CSV", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)
            }

            Divider().frame(height: 22)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search filenames…", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 160)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)

            Spacer()

            dashboardContent()
        }
        .padding(10)
        .background(Color(NSColor.windowBackgroundColor))
    }

}

// MARK: - Settings Tab

struct SettingsTabView: View {
    @Binding var settings: ScanPerformanceSettings
    let totalRAMGB: Int

    private func ramDiskColor(_ gb: Int) -> Color {
        let pct = Double(gb) / Double(totalRAMGB)
        if pct > 0.5 { return .red }
        if pct > 0.30 { return .yellow }
        return .green
    }

    private func floorColor(_ gb: Int) -> Color {
        if gb < 2 { return .red }
        if gb < 4 { return .yellow }
        return .green
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // Header
                HStack(spacing: 12) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.largeTitle)
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Performance Settings")
                            .font(.title2.weight(.semibold))
                        Text("\(totalRAMGB) GB physical RAM")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    let mem = MemoryPressureMonitor.shared.availableMemoryString()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Available Now")
                            .font(.caption).foregroundColor(.secondary)
                        Text(mem)
                            .font(.system(.title3, design: .monospaced).weight(.medium))
                            .foregroundColor(.green)
                    }
                }

                Divider()

                // Scanning section
                VStack(alignment: .leading, spacing: 16) {
                    Label("Scanning", systemImage: "magnifyingglass")
                        .font(.headline)

                    settingRow(
                        title: "Probes per volume",
                        value: "\(settings.probesPerVolume)",
                        description: "Concurrent ffprobe processes per volume",
                        slider: Slider(value: Binding(
                            get: { Double(settings.probesPerVolume) },
                            set: { settings.probesPerVolume = Int($0) }
                        ), in: 1...32, step: 1)
                    )

                    settingRow(
                        title: "Memory floor",
                        value: "\(settings.memoryFloorGB) GB",
                        valueColor: floorColor(settings.memoryFloorGB),
                        description: "Auto-pause scanning when free RAM drops below this",
                        slider: Slider(value: Binding(
                            get: { Double(settings.memoryFloorGB) },
                            set: { settings.memoryFloorGB = Int($0) }
                        ), in: 1...Double(max(1, totalRAMGB / 4)), step: 1)
                    )
                }

                Divider()

                // Network section
                VStack(alignment: .leading, spacing: 16) {
                    Label("Network Volumes", systemImage: "network")
                        .font(.headline)

                    settingRow(
                        title: "RAM disk size",
                        value: "\(settings.ramDiskGB) GB",
                        valueColor: ramDiskColor(settings.ramDiskGB),
                        description: "Temporary RAM disk for network file prefetch (mounted at /Volumes/VideoScan_Temp)",
                        slider: Slider(value: Binding(
                            get: { Double(settings.ramDiskGB) },
                            set: { settings.ramDiskGB = Int($0) }
                        ), in: 1...Double(max(1, totalRAMGB / 2)), step: 1)
                    )

                    settingRow(
                        title: "Prefetch size",
                        value: "\(settings.prefetchMB) MB",
                        description: "Header bytes copied per network file before probing",
                        slider: Slider(value: Binding(
                            get: { Double(settings.prefetchMB) },
                            set: { settings.prefetchMB = Int($0) }
                        ), in: 10...200, step: 10)
                    )
                }

                Divider()

                // Combine section
                VStack(alignment: .leading, spacing: 16) {
                    Label("Combine / Mux", systemImage: "arrow.triangle.merge")
                        .font(.headline)

                    settingRow(
                        title: "Combine tasks",
                        value: "\(settings.combineConcurrency)",
                        description: "Concurrent ffmpeg mux processes",
                        slider: Slider(value: Binding(
                            get: { Double(settings.combineConcurrency) },
                            set: { settings.combineConcurrency = Int($0) }
                        ), in: 1...16, step: 1)
                    )
                }

                Divider()

                HStack {
                    Button("Reset All to Defaults") {
                        settings = ScanPerformanceSettings()
                        settings.save()
                    }
                    .controlSize(.large)
                }
            }
            .padding(30)
            .frame(maxWidth: 600, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func settingRow(
        title: String,
        value: String,
        valueColor: Color = .secondary,
        description: String,
        slider: some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.body)
                Spacer()
                Text(value)
                    .font(.system(.body, design: .monospaced).weight(.medium))
                    .foregroundColor(valueColor)
            }
            slider
            Text(description)
                .font(.caption).foregroundColor(.secondary)
        }
    }
}

// MARK: - Table + Preview (NO @ObservedObject — only re-renders when passed values change)

private struct CatalogContent: View {
    let records: [VideoRecord]
    @Binding var selectedIDs: Set<UUID>
    @Binding var sortOrder: [KeyPathComparator<VideoRecord>]
    let searchText: String
    let previewImage: NSImage?
    let previewFilename: String
    let onSort: ([KeyPathComparator<VideoRecord>]) -> Void
    let onSelect: (UUID?) -> Void
    let onClearPreview: () -> Void

    @State private var player: AVPlayer?
    @State private var isPlaying = false

    private var filteredRecords: [VideoRecord] {
        if searchText.isEmpty { return records }
        let q = searchText.lowercased()
        return records.filter {
            $0.filename.lowercased().contains(q) ||
            $0.directory.lowercased().contains(q)
        }
    }

    var body: some View {
        VSplitView {

            // MARK: Results Table
            Table(filteredRecords, selection: $selectedIDs, sortOrder: $sortOrder) {
                TableColumn("Filename", value: \.filename) { rec in
                    Text(rec.filename)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                }
                .width(min: 200, ideal: 260)

                TableColumn("Stream Type", value: \.streamTypeRaw) { rec in
                    Text(rec.streamTypeRaw)
                        .foregroundColor(streamTypeColor(rec.streamType))
                        .bold(rec.streamType.needsCorrelation)
                }
                .width(min: 100, ideal: 110)

                TableColumn("Duration", value: \.duration)
                    .width(min: 70, ideal: 80)

                TableColumn("Resolution", value: \.resolution)
                    .width(min: 90, ideal: 100)

                TableColumn("Timecode", value: \.timecode)
                    .width(min: 100, ideal: 110)

                TableColumn("Paired With") { rec in
                    HStack(spacing: 4) {
                        if let conf = rec.pairConfidence {
                            Circle()
                                .fill(conf.textColor)
                                .frame(width: 8, height: 8)
                        }
                        Text(rec.pairedWith?.filename ?? "—")
                            .foregroundColor(rec.pairConfidence?.textColor ?? .secondary)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .width(min: 200, ideal: 280)

                TableColumn("Date Created", value: \.dateCreated)
                    .width(min: 130, ideal: 150)

                TableColumn("Size", value: \.size)
                    .width(min: 70, ideal: 80)

                TableColumn("Video Codec", value: \.videoCodec)
                    .width(min: 80, ideal: 90)

                TableColumn("Directory", value: \.directory) { rec in
                    Text(rec.directory)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .width(min: 200, ideal: 300)
            }
            .onChange(of: sortOrder) {
                onSort(sortOrder)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first,
                   let rec = records.first(where: { $0.id == id }) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(rec.fullPath, inFileViewerRootedAtPath: "")
                    }
                    Button("Open in QuickTime Player") {
                        if let qtURL = NSWorkspace.shared.urlForApplication(
                            withBundleIdentifier: "com.apple.QuickTimePlayerX"
                        ) {
                            NSWorkspace.shared.open(
                                [URL(fileURLWithPath: rec.fullPath)],
                                withApplicationAt: qtURL,
                                configuration: NSWorkspace.OpenConfiguration()
                            )
                        }
                    }
                    Divider()
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(rec.fullPath, forType: .string)
                    }
                }
            }
            .onChange(of: selectedIDs) {
                if let id = selectedIDs.first {
                    onSelect(id)
                } else {
                    onClearPreview()
                }
            }
            .frame(minHeight: 250)

            // MARK: Preview / Player
            VStack(spacing: 0) {
                if previewImage != nil || !previewFilename.isEmpty {
                    VStack(spacing: 8) {
                        if isPlaying, let player = player {
                            VideoPlayer(player: player)
                                .cornerRadius(6)
                                .shadow(radius: 3)
                        } else if let img = previewImage {
                            ZStack {
                                Image(nsImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .cornerRadius(6)
                                    .shadow(radius: 3)

                                // Play button overlay
                                if let id = selectedIDs.first,
                                   let rec = records.first(where: { $0.id == id }),
                                   rec.streamType == .videoAndAudio || rec.streamType == .videoOnly {
                                    Button {
                                        let url = URL(fileURLWithPath: rec.fullPath)
                                        player = AVPlayer(url: url)
                                        isPlaying = true
                                        player?.play()
                                    } label: {
                                        Image(systemName: "play.circle.fill")
                                            .font(.system(size: 48))
                                            .foregroundColor(.white.opacity(0.85))
                                            .shadow(radius: 4)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.gray.opacity(0.1))
                                    .frame(width: 240, height: 135)
                                ProgressView()
                            }
                        }

                        // File info + stop button
                        if let id = selectedIDs.first,
                           let rec = records.first(where: { $0.id == id }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(previewFilename)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text("\(rec.resolution)  \(rec.duration)  \(rec.videoCodec)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if isPlaying {
                                    Button {
                                        player?.pause()
                                        player = nil
                                        isPlaying = false
                                    } label: {
                                        Image(systemName: "stop.fill")
                                            .font(.system(size: 12))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(12)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary.opacity(0.4))
                        Text("Select a video to preview")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(minHeight: 180, idealHeight: 280)
            .background(Color(NSColor.controlBackgroundColor))
            .onChange(of: selectedIDs) {
                // Stop playback when selection changes
                if isPlaying {
                    player?.pause()
                    player = nil
                    isPlaying = false
                }
            }
        }
    }

    private func streamTypeColor(_ st: StreamType) -> Color {
        switch st {
        case .videoOnly:     return .orange
        case .audioOnly:     return .yellow
        case .ffprobeFailed: return .red
        default:             return .primary
        }
    }
}
