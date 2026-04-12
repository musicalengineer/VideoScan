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
    @State private var showInspector = true
    @State private var sortOrder = [KeyPathComparator(\VideoRecord.filename)]
    @State private var searchText: String = ""
    /// Set of scan-target searchPaths whose records the user wants to see in
    /// the catalog table. Empty set = show all volumes (no filter). Each eye
    /// toggle in the Scan Targets pane independently flips membership, so the
    /// user can view 1, 2, or N volumes simultaneously. Works for offline
    /// volumes too, since records are persisted across launches.
    @State private var filterTargetPaths: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {

            // MARK: Scan Targets Pane
            scanTargetsPane

            Divider()

            // MARK: Toolbar (post-scan actions)
            CatalogToolbar(
                isScanning: model.isScanning,
                isCombining: model.isCombining,
                isCorrelating: model.isCorrelating,
                isAnalyzingDuplicates: model.isAnalyzingDuplicates,
                hasRecords: !model.records.isEmpty,
                hasCorrelatedPairs: !model.correlatedPairs.isEmpty,
                outputCSVPath: model.outputCSVPath,
                selectedIDs: selectedIDs,
                showCombineSheet: $showCombineSheet,
                showDashboard: $showDashboard,
                searchText: $searchText,
                showInspector: $showInspector,
                cacheCount: model.cacheCount,
                dashboard: model.dashboard,
                onStopCombine: { model.stopCombine() },
                onCorrelateAll: {
                    model.log("\nCorrelating all audio-only and video-only files...")
                    model.correlate()
                },
                onCorrelateSelected: {
                    model.log("\nCorrelating \(selectedIDs.count) selected files...")
                    model.correlate(selectedIDs: selectedIDs)
                },
                onAnalyzeDuplicatesAll: {
                    model.log("\nAnalyzing duplicate candidates across all scanned media...")
                    model.analyzeDuplicates()
                },
                onAnalyzeDuplicatesSelected: {
                    model.log("\nAnalyzing duplicate candidates in \(selectedIDs.count) selected files...")
                    model.analyzeDuplicates(selectedIDs: selectedIDs)
                },
                onClearResults: { model.clearResults() },
                onClearCache: { _ = model.clearCache() },
                onScanAvidBins: { model.scanAvidBins() },
                avidBinCount: model.avidBinResults.reduce(0) { $0 + $1.clips.count },
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

            // MARK: Split — Table + Player left, Inspector right
            CatalogContent(
                records: model.records,
                selectedIDs: $selectedIDs,
                sortOrder: $sortOrder,
                searchText: searchText,
                filterTargetPaths: filterTargetPaths,
                previewImage: model.previewImage,
                previewFilename: model.previewFilename,
                previewOfflineVolumeName: model.previewOfflineVolumeName,
                showInspector: $showInspector,
                onSort: { model.records.sort(using: $0) },
                onSelect: { id in
                    if let rec = model.records.first(where: { $0.id == id }),
                       rec.streamType == .videoOnly || rec.streamType == .videoAndAudio {
                        model.generateThumbnail(for: rec)
                    } else {
                        model.previewImage = nil
                        model.previewFilename = ""
                        model.previewOfflineVolumeName = nil
                    }
                },
                onClearPreview: {
                    model.previewImage = nil
                    model.previewFilename = ""
                    model.previewOfflineVolumeName = nil
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
                                recordCount: model.records.reduce(into: 0) { count, rec in
                                    if rec.fullPath.hasPrefix(target.searchPath) { count += 1 }
                                },
                                isFiltered: filterTargetPaths.contains(target.searchPath),
                                onStart: { model.startTarget(target) },
                                onStop: { model.stopTarget(target) },
                                onPause: { model.togglePauseTarget(target) },
                                onReset: { model.resetTarget(target) },
                                onRemove: { model.removeScanTarget(target) },
                                onViewCatalog: {
                                    if filterTargetPaths.contains(target.searchPath) {
                                        filterTargetPaths.remove(target.searchPath)
                                    } else {
                                        filterTargetPaths.insert(target.searchPath)
                                    }
                                }
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
    @ObservedObject var target: CatalogScanTarget
    let recordCount: Int
    let isFiltered: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onPause: () -> Void
    let onReset: () -> Void
    let onRemove: () -> Void
    let onViewCatalog: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Status dot
            Circle()
                .fill(target.status.color)
                .frame(width: 12, height: 12)
                .shadow(color: target.status.color.opacity(0.5), radius: 3)

            // Focus toggle — switches the catalog table between "all volumes"
            // and "only this volume". eye.fill + accent = focused on this one;
            // eye + secondary = global (all volumes shown). Record count rides
            // inside the same control so the row stays clean.
            Button(action: onViewCatalog) {
                HStack(spacing: 4) {
                    Image(systemName: isFiltered ? "eye.fill" : "eye")
                        .font(.system(size: 13))
                    if recordCount > 0 {
                        Text("\(recordCount)")
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
                .foregroundColor(isFiltered ? .accentColor : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isFiltered ? Color.accentColor.opacity(0.15) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isFiltered ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help(isFiltered
                  ? "Showing only this volume in the catalog — click to show all volumes"
                  : (recordCount == 0
                     ? "No catalog data for this volume yet"
                     : "Show only this volume's catalog data"))

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

            // Offline indicator — independent of the status dot, which conveys
            // scan progress. Shown whenever the root path is unreachable.
            if !target.isReachable {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .foregroundColor(.orange)
                    .help("Volume offline — \(VolumeReachability.volumeName(forPath: target.searchPath)) is not currently mounted")
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
                .disabled(target.searchPath.isEmpty || !target.isReachable)
                .help(target.isReachable ? "" : "Volume offline — mount the drive to scan")

                if target.status == .complete || target.status == .stopped || target.status == .error {
                    Button(action: onReset) {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Reset progress and drop cached probes for this volume so a re-scan re-runs ffprobe")
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
    let isCorrelating: Bool
    let isAnalyzingDuplicates: Bool
    let hasRecords: Bool
    let hasCorrelatedPairs: Bool
    let outputCSVPath: String
    let selectedIDs: Set<UUID>
    @Binding var showCombineSheet: Bool
    @Binding var showDashboard: Bool
    @Binding var searchText: String
    @Binding var showInspector: Bool
    let cacheCount: Int
    let dashboard: DashboardState
    let onStopCombine: () -> Void
    let onCorrelateAll: () -> Void
    let onCorrelateSelected: () -> Void
    let onAnalyzeDuplicatesAll: () -> Void
    let onAnalyzeDuplicatesSelected: () -> Void
    let onClearResults: () -> Void
    let onClearCache: () -> Void
    let onScanAvidBins: () -> Void
    let avidBinCount: Int
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
                Button("Clear All Cache — All Volumes (\(cacheCount) entries)") { onClearCache() }
                    .disabled(cacheCount == 0)
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 80)
            .disabled(isScanning)
            .help("Clear catalog results or cached probe data")

            Divider().frame(height: 22)

            Menu {
                Button("Correlate All", action: onCorrelateAll)
                Button("Correlate Selected", action: onCorrelateSelected)
                    .disabled(selectedIDs.isEmpty)
            } label: {
                if isCorrelating {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Correlating…")
                    }
                } else {
                    Label("Correlate", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 120)
            .disabled(isScanning || isCorrelating || !hasRecords)
            .help("Match video-only files with their corresponding audio-only files (e.g. Avid MXF pairs)")

            Menu {
                Button("Analyze All", action: onAnalyzeDuplicatesAll)
                Button("Analyze Selected", action: onAnalyzeDuplicatesSelected)
                    .disabled(selectedIDs.isEmpty)
            } label: {
                if isAnalyzingDuplicates {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Analyzing…")
                    }
                } else {
                    Label("Duplicates", systemImage: "doc.on.doc")
                }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 120)
            .disabled(isScanning || isAnalyzingDuplicates || !hasRecords)
            .help("Find duplicate files by comparing hash, duration, filename, resolution, and other signals")

            Button(action: onScanAvidBins) {
                HStack(spacing: 4) {
                    Label("Avid Bins", systemImage: "film.stack")
                    if avidBinCount > 0 {
                        Text("\(avidBinCount)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                }
            }
            .buttonStyle(.bordered)
            .disabled(isScanning)
            .help("Scan target volumes for Avid .avb bin files and cross-reference with MXF media")

            Button(action: { showCombineSheet = true }) {
                Label("Combine", systemImage: "rectangle.stack.badge.plus")
            }
            .buttonStyle(.bordered)
            .disabled(!canCombine && !isCombining)
            .help("Mux correlated video + audio pairs into combined files using ffmpeg (no re-encode)")

            if isCombining {
                Button(action: onStopCombine) {
                    Label("Stop Combine", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            Button {
                CatalogScanWindowController.shared.show(dashboard: dashboard)
            } label: {
                Label("Realtime Scan", systemImage: "waveform.path.ecg.rectangle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)

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

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showInspector.toggle()
                }
            } label: {
                Image(systemName: showInspector ? "sidebar.right" : "sidebar.right")
                    .font(.system(size: 14))
                    .foregroundColor(showInspector ? .accentColor : .secondary)
            }
            .buttonStyle(.bordered)
            .help(showInspector ? "Hide Inspector" : "Show Inspector")

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

// MARK: - Table + Preview + Inspector

private struct CatalogContent: View {
    let records: [VideoRecord]
    @Binding var selectedIDs: Set<UUID>
    @Binding var sortOrder: [KeyPathComparator<VideoRecord>]
    let searchText: String
    let filterTargetPaths: Set<String>
    let previewImage: NSImage?
    let previewFilename: String
    let previewOfflineVolumeName: String?
    @Binding var showInspector: Bool
    let onSort: ([KeyPathComparator<VideoRecord>]) -> Void
    let onSelect: (UUID?) -> Void
    let onClearPreview: () -> Void

    @State private var player: AVPlayer?
    @State private var isPlaying = false

    /// Stable snapshot the Table reads from. Decoupled from `records` so the
    /// Table never sees the data array mutate mid-gesture (which races with
    /// AppKit's canDragRows / mouseDown handling and crashes inside
    /// ForEach.IDGenerator with an out-of-bounds subscript).
    @State private var tableData: [VideoRecord] = []

    private var selectedRecord: VideoRecord? {
        guard let id = selectedIDs.first else { return nil }
        return records.first(where: { $0.id == id })
    }

    private func computeFiltered() -> [VideoRecord] {
        var out = records
        if !filterTargetPaths.isEmpty {
            let prefixes = Array(filterTargetPaths)
            out = out.filter { rec in
                prefixes.contains(where: { rec.fullPath.hasPrefix($0) })
            }
        }
        if searchText.isEmpty { return out }
        let q = searchText.lowercased()
        return out.filter {
            $0.filename.lowercased().contains(q) ||
            $0.directory.lowercased().contains(q) ||
            $0.duplicateDisposition.rawValue.lowercased().contains(q) ||
            $0.duplicateBestMatchFilename.lowercased().contains(q) ||
            $0.duplicateReasons.lowercased().contains(q)
        }
    }

    var body: some View {
        HSplitView {
            // MARK: Left side — Table + Player
            VSplitView {
                catalogTable
                    .frame(minHeight: 250)

                previewPlayer
                    .frame(minHeight: 140, idealHeight: 220)
                    .background(Color(NSColor.controlBackgroundColor))
            }
            .frame(minWidth: 500)

            // MARK: Right side — Inspector
            if showInspector {
                InspectorPanel(
                    record: selectedRecord,
                    previewImage: previewImage,
                    previewOfflineVolumeName: previewOfflineVolumeName
                )
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 400)
            }
        }
        .onChange(of: selectedIDs) {
            if isPlaying {
                player?.pause()
                player = nil
                isPlaying = false
            }
            if let id = selectedIDs.first {
                onSelect(id)
            } else {
                onClearPreview()
            }
        }
    }

    // MARK: - Results Table

    private var catalogTable: some View {
        Table(tableData, selection: $selectedIDs, sortOrder: $sortOrder) {
            TableColumn("Filename", value: \.filename) { rec in
                Text(rec.filename)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                    .help("Media filename from disk")
            }
            .width(min: 180, ideal: 260)

            TableColumn("Stream", value: \.streamTypeRaw) { rec in
                let display = rec.streamType == .ffprobeFailed
                    ? rec.isPlayable
                    : rec.streamTypeRaw
                Text(display)
                    .foregroundColor(streamTypeColor(rec.streamType))
                    .bold(rec.streamType.needsCorrelation)
                    .help("V+A = video and audio, V-only/A-only = single stream, or file status if damaged")
            }
            .width(min: 90, ideal: 130)

            TableColumn("Duration", value: \.durationSeconds) { rec in
                Text(rec.duration)
                    .help("Playback duration (HH:MM:SS)")
            }
            .width(min: 65, ideal: 75)

            TableColumn("Resolution", value: \.pixelCount) { rec in
                Text(rec.resolution)
                    .help("Video frame size (width x height)")
            }
            .width(min: 80, ideal: 95)

            TableColumn("Codec", value: \.videoCodec) { rec in
                Text(rec.videoCodec.isEmpty ? "—" : rec.videoCodec)
                    .foregroundColor(rec.videoCodec.isEmpty ? .secondary : .primary)
                    .help("Video codec (e.g. h264, prores, mpeg2video)")
            }
            .width(min: 60, ideal: 80)

            TableColumn("Size", value: \.sizeBytes) { rec in
                Text(rec.size)
                    .help("File size on disk")
            }
            .width(min: 60, ideal: 75)

            TableColumn("Created", value: \.dateCreatedSortKey) { rec in
                Text(rec.dateCreated.isEmpty ? "—" : rec.dateCreated)
                    .foregroundColor(rec.dateCreated.isEmpty ? .secondary : .primary)
                    .font(.system(size: 11))
                    .help("File creation date from filesystem metadata")
            }
            .width(min: 80, ideal: 100)

            TableColumn("Duplicate") { rec in
                DuplicateDispositionCell(record: rec)
                    .help(rec.duplicateDisposition == .none
                          ? "Run Duplicates analysis to check for copies"
                          : "Keep = best copy, Review = check manually, Extra copy = safe to remove")
            }
            .width(min: 80, ideal: 95)
        }
        .onChange(of: sortOrder) {
            onSort(sortOrder)
            tableData.sort(using: sortOrder)
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
        .onAppear { tableData = computeFiltered() }
        .onChange(of: records.count)     { tableData = computeFiltered() }
        .onChange(of: searchText)        { tableData = computeFiltered() }
        .onChange(of: filterTargetPaths) { tableData = computeFiltered() }
    }

    // MARK: - Preview / Player

    private var previewPlayer: some View {
        Group {
            if previewOfflineVolumeName != nil {
                VStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black)
                        Text("MEDIA OFFLINE")
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundColor(.orange)
                            .tracking(2)
                    }
                    .frame(maxWidth: 480, maxHeight: 180)
                    .aspectRatio(16.0/9.0, contentMode: .fit)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
            } else if previewImage != nil || !previewFilename.isEmpty {
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

                            if let rec = selectedRecord,
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

                    // Filename + stop button
                    HStack {
                        Text(previewFilename)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
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
                .frame(height: 140)
                .frame(maxWidth: .infinity)
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

// MARK: - Inspector Panel

private struct InspectorPanel: View {
    let record: VideoRecord?
    let previewImage: NSImage?
    let previewOfflineVolumeName: String?

    var body: some View {
        if let rec = record {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Thumbnail
                    inspectorThumbnail(for: rec)

                    // Filename header
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rec.filename)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Text(rec.streamType == .ffprobeFailed ? rec.isPlayable : rec.streamTypeRaw)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(streamTypeColor(rec.streamType))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(streamTypeColor(rec.streamType).opacity(0.12))
                            )
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                    Divider().padding(.horizontal, 16)

                    // Sections
                    inspectorSection("General", systemImage: "doc") {
                        inspectorRow("Size", rec.size)
                        inspectorRow("Duration", rec.duration)
                        inspectorRow("Container", rec.container)
                        inspectorRow("Extension", rec.ext)
                    }

                    inspectorSection("Video", systemImage: "film") {
                        inspectorRow("Resolution", rec.resolution)
                        inspectorRow("Codec", rec.videoCodec)
                        inspectorRow("Frame Rate", rec.frameRate)
                        inspectorRow("Bitrate", rec.videoBitrate)
                        inspectorRow("Total Bitrate", rec.totalBitrate)
                        inspectorRow("Color Space", rec.colorSpace)
                        inspectorRow("Bit Depth", rec.bitDepth)
                        inspectorRow("Scan Type", rec.scanType)
                    }

                    inspectorSection("Audio", systemImage: "speaker.wave.2") {
                        inspectorRow("Codec", rec.audioCodec)
                        inspectorRow("Channels", rec.audioChannels)
                        inspectorRow("Sample Rate", rec.audioSampleRate)
                    }

                    inspectorSection("Timestamps", systemImage: "calendar") {
                        inspectorRow("Created", rec.dateCreated)
                        inspectorRow("Modified", rec.dateModified)
                        inspectorRow("Timecode", rec.timecode)
                        inspectorRow("Tape Name", rec.tapeName)
                    }

                    if rec.pairedWith != nil || rec.pairConfidence != nil {
                        inspectorSection("Correlation", systemImage: "arrow.triangle.2.circlepath") {
                            if let paired = rec.pairedWith {
                                inspectorRow("Paired With", paired.filename)
                            }
                            if let conf = rec.pairConfidence {
                                HStack(spacing: 6) {
                                    Text("Confidence")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .frame(width: 80, alignment: .trailing)
                                    Circle()
                                        .fill(conf.textColor)
                                        .frame(width: 8, height: 8)
                                    Text(conf.rawValue)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(conf.textColor)
                                    Spacer()
                                }
                            }
                        }
                    }

                    if rec.duplicateDisposition != .none || !rec.duplicateBestMatchFilename.isEmpty {
                        inspectorSection("Duplicates", systemImage: "doc.on.doc") {
                            if rec.duplicateDisposition != .none {
                                HStack(spacing: 6) {
                                    Text("Status")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .frame(width: 80, alignment: .trailing)
                                    Circle()
                                        .fill(rec.duplicateDisposition.textColor)
                                        .frame(width: 8, height: 8)
                                    Text(rec.duplicateDisposition.rawValue)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(rec.duplicateDisposition.textColor)
                                    Spacer()
                                }
                            }
                            inspectorRow("Match", rec.duplicateBestMatchFilename)
                            inspectorRow("Reasons", rec.duplicateReasons)
                            if let conf = rec.duplicateConfidence {
                                HStack(spacing: 6) {
                                    Text("Confidence")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .frame(width: 80, alignment: .trailing)
                                    Circle()
                                        .fill(conf.textColor)
                                        .frame(width: 8, height: 8)
                                    Text(conf.rawValue)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(conf.textColor)
                                    Spacer()
                                }
                            }
                        }
                    }

                    if rec.hasAvidMetadata {
                        inspectorSection("Avid Project", systemImage: "film.stack") {
                            inspectorRow("Clip Name", rec.avidClipName)
                            inspectorRow("Mob Type", rec.avidMobType)
                            inspectorRow("Bin File", rec.avidBinFile)
                            inspectorRow("Tape", rec.avidTapeName)
                            inspectorRow("Tracks", rec.avidTracks)
                            inspectorRow("Edit Rate", rec.avidEditRate > 0 ? String(format: "%.2f fps", rec.avidEditRate) : "")
                            inspectorCopyableRow("Mob ID", rec.avidMobID)
                            inspectorCopyableRow("Material UUID", rec.avidMaterialUUID)
                            inspectorCopyableRow("Original Path", rec.avidMediaPath)
                        }
                    }

                    inspectorSection("Location", systemImage: "folder") {
                        inspectorCopyableRow("Path", rec.fullPath)
                        inspectorRow("Directory", rec.directory)
                        inspectorRow("MD5 (partial)", rec.partialMD5)
                    }

                    Spacer(minLength: 16)
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.4))
                Text("No Selection")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Text("Select a file to view details")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private func inspectorThumbnail(for rec: VideoRecord) -> some View {
        if previewOfflineVolumeName != nil {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black)
                Text("OFFLINE")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.orange)
            }
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .padding(16)
        } else if let img = previewImage {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .cornerRadius(6)
                .shadow(radius: 2)
                .frame(maxWidth: .infinity)
                .padding(16)
        } else if rec.streamType == .audioOnly {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
                Image(systemName: "waveform")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .frame(height: 80)
            .frame(maxWidth: .infinity)
            .padding(16)
        } else {
            EmptyView()
        }
    }

    // MARK: - Section Builder

    @ViewBuilder
    private func inspectorSection(_ title: String, systemImage: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            content()
                .padding(.horizontal, 16)
        }
    }

    // MARK: - Row Helpers

    @ViewBuilder
    private func inspectorRow(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .trailing)
                Text(value)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func inspectorCopyableRow(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .trailing)
                Text(value)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
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

// MARK: - Table Cell Views

private struct DuplicateDispositionCell: View {
    let record: VideoRecord

    var body: some View {
        HStack(spacing: 4) {
            if let conf = record.duplicateConfidence {
                Circle()
                    .fill(conf.textColor)
                    .frame(width: 8, height: 8)
            }
            Text(record.duplicateDisposition == .none ? "—" : record.duplicateDisposition.rawValue)
                .foregroundColor(record.duplicateDisposition.textColor)
        }
    }
}
