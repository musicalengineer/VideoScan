import SwiftUI
import Combine
import AVKit

// MARK: - Root (Tab switcher)

struct ContentView: View {
    @EnvironmentObject var model: VideoScanModel

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                CatalogView()
                    .tabItem { Label("Video Catalog", systemImage: "film.stack") }
                PersonFinderView()
                    .tabItem { Label("Person Finder", systemImage: "person.crop.rectangle.stack") }
            }

            // Performance settings bar — always visible at bottom of window
            HStack {
                Spacer()
                PerformancePopover(
                    settings: Binding(
                        get: { model.perfSettings },
                        set: { model.perfSettings = $0 }
                    ),
                    totalRAMGB: Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
                )
                let mem = MemoryPressureMonitor.shared.availableMemoryString()
                Text(mem)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

// MARK: - Catalog Tab

struct CatalogView: View {
    @EnvironmentObject var model: VideoScanModel
    @State private var scanPaths: [String] = []
    @State private var selectedIDs: Set<UUID> = []
    @State private var showCombineSheet = false
    @State private var showDashboard = false
    @State private var sortOrder = [KeyPathComparator(\VideoRecord.filename)]
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {

            // MARK: Scan Paths
            if !scanPaths.isEmpty && !model.isScanning {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(scanPaths.enumerated()), id: \.offset) { i, path in
                        HStack(spacing: 4) {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.blue)
                                .font(.caption)
                            Text(path)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(action: { scanPaths.remove(at: i) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)
            }

            // MARK: Toolbar
            CatalogToolbar(
                isScanning: model.isScanning,
                isCombining: model.isCombining,
                isPaused: model.isPaused,
                hasRecords: !model.records.isEmpty,
                hasCorrelatedPairs: !model.correlatedPairs.isEmpty,
                outputCSVPath: model.outputCSVPath,
                scanPaths: $scanPaths,
                selectedIDs: selectedIDs,
                showCombineSheet: $showCombineSheet,
                showDashboard: $showDashboard,
                searchText: $searchText,
                cacheCount: model.cacheCount,
                onScan: { model.startScan(roots: scanPaths) },
                onStop: { model.stopScan() },
                onPause: { model.togglePause() },
                onStopCombine: { model.stopCombine() },
                onCorrelateAll: {
                    model.log("\nCorrelating all audio-only and video-only files...")
                    model.correlate()
                },
                onCorrelateSelected: {
                    model.log("\nCorrelating \(selectedIDs.count) selected files...")
                    model.correlate(selectedIDs: selectedIDs)
                },
                onClearPaths: { scanPaths = [] },
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
}

// MARK: - Toolbar (reads model state flags via value params — no @ObservedObject)

private struct CatalogToolbar<Dashboard: View>: View {
    let isScanning: Bool
    let isCombining: Bool
    let isPaused: Bool
    let hasRecords: Bool
    let hasCorrelatedPairs: Bool
    let outputCSVPath: String
    @Binding var scanPaths: [String]
    let selectedIDs: Set<UUID>
    @Binding var showCombineSheet: Bool
    @Binding var showDashboard: Bool
    @Binding var searchText: String
    let cacheCount: Int
    let onScan: () -> Void
    let onStop: () -> Void
    let onPause: () -> Void
    let onStopCombine: () -> Void
    let onCorrelateAll: () -> Void
    let onCorrelateSelected: () -> Void
    let onClearPaths: () -> Void
    let onClearResults: () -> Void
    let onClearCache: () -> Void
    @ViewBuilder let dashboardContent: () -> Dashboard

    private var canCombine: Bool {
        guard !isScanning && !isCombining else { return false }
        return hasCorrelatedPairs
    }

    var body: some View {
        HStack(spacing: 10) {
            Button("Add Volumes…") { browseForFolders() }
                .disabled(isScanning)

            Menu {
                Button("Clear Paths") { onClearPaths() }
                    .disabled(scanPaths.isEmpty)
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

            Button(action: onScan) {
                Label("Scan", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isScanning || scanPaths.isEmpty)

            Button(action: onPause) {
                Label(isPaused ? "Resume" : "Pause",
                      systemImage: isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .disabled(!isScanning)

            Button(action: onStop) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .disabled(!isScanning)

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

    private func browseForFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Select volumes or folders to scan (⌘-click for multiple)"
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            for url in panel.urls {
                let path = url.path
                if !scanPaths.contains(path) {
                    scanPaths.append(path)
                }
            }
        }
    }
}

// MARK: - Performance Settings Popover

struct PerformancePopover: View {
    @Binding var settings: ScanPerformanceSettings
    let totalRAMGB: Int
    @State private var showPopover = false

    // Color coding: green → yellow → red based on how much RAM the setting consumes
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
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: "gearshape")
                .font(.body)
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.title3)
                    Text("Performance")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("\(totalRAMGB) GB RAM")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Probes per volume
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Probes / volume")
                        Spacer()
                        Text("\(settings.probesPerVolume)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.probesPerVolume) },
                        set: { settings.probesPerVolume = Int($0) }
                    ), in: 1...32, step: 1)
                    Text("Concurrent ffprobe processes per volume")
                        .font(.caption).foregroundColor(.secondary)
                }

                // RAM disk size
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("RAM disk")
                        Spacer()
                        Text("\(settings.ramDiskGB) GB")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(ramDiskColor(settings.ramDiskGB))
                    }
                    Slider(value: Binding(
                        get: { Double(settings.ramDiskGB) },
                        set: { settings.ramDiskGB = Int($0) }
                    ), in: 1...Double(max(1, totalRAMGB / 2)), step: 1)
                    Text("For network volume prefetch (allocated at mount)")
                        .font(.caption).foregroundColor(.secondary)
                }

                // Prefetch size
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Prefetch size")
                        Spacer()
                        Text("\(settings.prefetchMB) MB")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.prefetchMB) },
                        set: { settings.prefetchMB = Int($0) }
                    ), in: 10...200, step: 10)
                    Text("Header bytes copied per network file")
                        .font(.caption).foregroundColor(.secondary)
                }

                // Combine concurrency
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Combine tasks")
                        Spacer()
                        Text("\(settings.combineConcurrency)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.combineConcurrency) },
                        set: { settings.combineConcurrency = Int($0) }
                    ), in: 1...16, step: 1)
                    Text("Concurrent ffmpeg mux processes")
                        .font(.caption).foregroundColor(.secondary)
                }

                // Memory floor
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Memory floor")
                        Spacer()
                        Text("\(settings.memoryFloorGB) GB")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(floorColor(settings.memoryFloorGB))
                    }
                    Slider(value: Binding(
                        get: { Double(settings.memoryFloorGB) },
                        set: { settings.memoryFloorGB = Int($0) }
                    ), in: 1...Double(max(1, totalRAMGB / 4)), step: 1)
                    Text("Auto-pause when free RAM drops below this")
                        .font(.caption).foregroundColor(.secondary)
                }

                Divider()

                HStack {
                    Button("Reset Defaults") {
                        settings = ScanPerformanceSettings()
                        settings.save()
                    }
                    .controlSize(.small)
                    Spacer()
                    let mem = MemoryPressureMonitor.shared.availableMemoryString()
                    Text("Available: \(mem)")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)
            .frame(width: 340)
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
