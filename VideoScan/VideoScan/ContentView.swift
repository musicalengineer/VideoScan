import SwiftUI
import Combine
import AVKit
import IOKit

// MARK: - Root (Tab switcher)

struct ContentView: View {
    @EnvironmentObject var model: VideoScanModel
    @StateObject private var personFinderModel = PersonFinderModel()
    @AppStorage("selectedTab") private var selectedTab: Int = 0
    private let tabFontSize: Double = 18

    private let tabs: [(label: String, icon: String, tag: Int)] = [
        ("People", "person.2.fill", 0),
        ("Media", "film.stack", 1),
        ("Settings", "gearshape", 2),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Custom tab bar — centered with traffic-light inset
            HStack(spacing: 0) {
                // Reserve space for window traffic-light buttons
                Color.clear.frame(width: 76, height: 1)

                Spacer()
                HStack(spacing: 24) {
                    ForEach(tabs, id: \.tag) { tab in
                        Button {
                            selectedTab = tab.tag
                        } label: {
                            Label(tab.label, systemImage: tab.icon)
                                .font(.system(size: tabFontSize, weight: selectedTab == tab.tag ? .bold : .regular))
                                .foregroundStyle(selectedTab == tab.tag ? .primary : .secondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            selectedTab == tab.tag
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .bottom) {
                            if selectedTab == tab.tag {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Color.accentColor)
                                    .frame(height: 2.5)
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
            Divider()

            // Tab content — fill all available space to prevent layout jumps
            Group {
                switch selectedTab {
                case 0:
                    PersonFinderView()
                        .environmentObject(personFinderModel)
                case 1:
                    CatalogView()
                case 2:
                    SettingsTabView(
                        settings: Binding(
                            get: { model.perfSettings },
                            set: { model.perfSettings = $0 }
                        ),
                        totalRAMGB: Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
                    )
                default:
                    PersonFinderView()
                        .environmentObject(personFinderModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

// MARK: - Volume Filter

enum VolumeFilter: String, CaseIterable, Hashable {
    case connected      = "Connected"
    case network        = "Network Drives"
    case allScanned     = "All Ever Scanned"
    case uncataloged    = "Uncataloged"
    case withErrors     = "With Errors"

    var icon: String {
        switch self {
        case .connected:   return "externaldrive.fill"
        case .network:     return "network"
        case .allScanned:  return "clock.arrow.circlepath"
        case .uncataloged: return "questionmark.folder"
        case .withErrors:  return "exclamationmark.triangle"
        }
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
    @State private var showDeleteDuplicatesConfirm = false
    @State private var deleteTargetVolume: String = ""
    @State private var deleteTargetCount: Int = 0
    @State private var showDiscoverVolumes = false
    @State private var showVolumeCompare = false
    // Volume pane height is now managed by NSSplitView (VerticalSplitView)
    @State private var showPairsOnly = false
    @State private var combinePairItem: CombinePairItem?
    /// Set of scan-target searchPaths whose records the user wants to see in
    /// the catalog table. Empty set = show all volumes (no filter). Each eye
    /// toggle in the Scan Targets pane independently flips membership, so the
    /// user can view 1, 2, or N volumes simultaneously. Works for offline
    /// volumes too, since records are persisted across launches.
    @State private var filterTargetPaths: Set<String> = []
    /// The searchPath of the volume containing the currently selected file.
    /// Used to highlight the matching volume row in the Scan Targets pane.
    @State private var highlightedTargetPath: String = ""
    /// Volume Options filter — controls which scan targets are visible.
    @State private var volumeFilters: Set<VolumeFilter> = [.allScanned]
    @State private var showDeleteAllCatalogConfirm = false
    @State private var showDeleteVolumeCatalogConfirm = false
    @State private var deleteVolumeCatalogTarget: CatalogScanTarget?
    /// Selected volume IDs in the scan volumes table.
    @State private var selectedVolumeIDs: Set<UUID> = []
    /// Catalog status alert for a volume.
    @State private var showCatalogStatusAlert = false
    @State private var catalogStatusAlertTitle = ""
    @State private var catalogStatusAlertText = ""

    var body: some View {
        VerticalSplitView(
            topMinHeight: 60,
            topIdealHeight: scanTargetsPaneAutoHeight,
            topMaxHeight: 400,
            top: {
                scanTargetsPane
            },
            bottom: {
                VStack(spacing: 0) {

            // MARK: Toolbar (post-scan actions)
            CatalogToolbar(
                isScanning: model.isScanning,
                isCombining: model.isCombining,
                isCorrelating: model.isCorrelating,
                isAnalyzingDuplicates: model.isAnalyzingDuplicates,
                correlateStatus: model.correlateStatus,
                duplicateStatus: model.duplicateStatus,
                videoOnlyCount: model.records.filter { $0.streamType == .videoOnly }.count,
                audioOnlyCount: model.records.filter { $0.streamType == .audioOnly }.count,
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
                volumesWithDeletableDups: model.volumesWithDeletableDuplicates(),
                onDeleteDuplicates: { path, count in
                    deleteTargetVolume = path
                    deleteTargetCount = count
                    showDeleteDuplicatesConfirm = true
                },
                onClearResults: { model.clearResults() },
                onClearCache: { _ = model.clearCache() },
                onScanAvidBins: { model.scanAvidBins() },
                avidBinCount: model.avidBinResults.reduce(0) { $0 + $1.clips.count },
                avidBinFiles: model.avidBinResults.count,
                showPairsOnly: $showPairsOnly,
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
                showPairsOnly: showPairsOnly,
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
                },
                onCombinePair: { video, audio in
                    // Delay sheet presentation to let the context menu dismiss first
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        combinePairItem = CombinePairItem(video: video, audio: audio)
                    }
                }
            )
            .onChange(of: selectedIDs) {
                // Update volume highlight when table selection changes
                if let id = selectedIDs.first,
                   let rec = model.records.first(where: { $0.id == id }) {
                    let path = rec.fullPath
                    highlightedTargetPath = model.scanTargets
                        .first(where: { !$0.searchPath.isEmpty && path.hasPrefix($0.searchPath) })?
                        .searchPath ?? ""
                } else {
                    highlightedTargetPath = ""
                }
            }
                }  // end bottom VStack
            }  // end VerticalSplitView
        )
        .sheet(isPresented: $showCombineSheet) {
            CombineSheet(selectedIDs: selectedIDs)
        }
        .sheet(item: $combinePairItem) { item in
            CombinePairSheet(video: item.video, audio: item.audio)
        }
        .alert("Delete Duplicates", isPresented: $showDeleteDuplicatesConfirm) {
            Button("Delete \(deleteTargetCount) Files", role: .destructive) {
                model.deleteDuplicates(onVolume: deleteTargetVolume)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently delete \(deleteTargetCount) high-confidence duplicate(s) on:\n\n\(deleteTargetVolume)\n\nOnly duplicates whose keeper is also on this same volume will be deleted. Cross-volume duplicates are never touched.\n\nAre you sure? Do you have backups and/or are these really junk or duplicates?")
        }
        .sheet(isPresented: $showDiscoverVolumes) {
            DiscoverVolumesSheet(model: model)
        }
        .sheet(isPresented: $showVolumeCompare) {
            VolumeCompareSheet(model: model)
        }
        .alert("Delete Catalog", isPresented: $showDeleteAllCatalogConfirm) {
            Button("Delete All", role: .destructive) {
                model.deleteAllCatalog()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will delete all \(model.records.count) catalog records across every volume. The probe cache is unaffected.\n\nAre you sure?")
        }
        .alert("Delete Volume Catalog", isPresented: $showDeleteVolumeCatalogConfirm) {
            Button("Delete", role: .destructive) {
                if let target = deleteVolumeCatalogTarget {
                    model.deleteCatalogForTarget(target)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let target = deleteVolumeCatalogTarget {
                let count = model.records.filter { $0.fullPath.hasPrefix(target.searchPath) }.count
                Text("Delete \(count) catalog record(s) for \(VolumeReachability.volumeName(forPath: target.searchPath))?\n\nThe probe cache is unaffected — a re-scan will replay quickly from cache.")
            } else {
                Text("Delete catalog records for this volume?")
            }
        }
    }

    // MARK: - Volume Filter Helpers

    private func toggleVolumeFilter(_ filter: VolumeFilter) {
        if filter == .allScanned {
            // "All Ever Scanned" also restores catalog-only volumes
            let count = model.restoreTargetsFromCatalog()
            if count > 0 {
                model.log("Restored \(count) volume(s) from catalog history.")
            }
        }
        if volumeFilters.contains(filter) {
            volumeFilters.remove(filter)
        } else {
            volumeFilters.insert(filter)
        }
        // If nothing is checked, default back to All Scanned
        if volumeFilters.isEmpty {
            volumeFilters = [.allScanned]
        }
    }

    static func buildCatalogStatus(records: [VideoRecord], target: CatalogScanTarget) -> String {
        guard !records.isEmpty else { return "No catalog data for this volume." }

        let totalBytes = records.reduce(into: Int64(0)) { $0 += $1.sizeBytes }
        let va = records.filter { $0.streamType == .videoAndAudio }.count
        let vo = records.filter { $0.streamType == .videoOnly }.count
        let ao = records.filter { $0.streamType == .audioOnly }.count
        let failedRecs = records.filter { $0.streamType == .ffprobeFailed }
        let noStreams = records.filter { $0.streamType == .noStreams }.count

        // Catalog size estimate
        let catBytes = records.count * 2048
        let catSize: String
        if catBytes < 1_048_576 {
            catSize = String(format: "%.0f KB", Double(catBytes) / 1024)
        } else {
            catSize = String(format: "%.1f MB", Double(catBytes) / 1_048_576)
        }

        // Media size
        let mediaSize: String
        if totalBytes < 1_073_741_824 {
            mediaSize = String(format: "%.1f MB", Double(totalBytes) / 1_048_576)
        } else {
            mediaSize = String(format: "%.1f GB", Double(totalBytes) / 1_073_741_824)
        }

        // Unique codecs, containers, resolutions
        let codecs = Set(records.compactMap { $0.videoCodec.isEmpty ? nil : $0.videoCodec })
        let containers = Set(records.compactMap { $0.container.isEmpty ? nil : $0.container })
        let resolutions = Set(records.compactMap { $0.resolution.isEmpty ? nil : $0.resolution })
        let audioCodecs = Set(records.compactMap { $0.audioCodec.isEmpty ? nil : $0.audioCodec })

        // Total duration
        let totalDuration = records.reduce(0.0) { $0 + $1.durationSeconds }
        let hours = Int(totalDuration) / 3600
        let mins = (Int(totalDuration) % 3600) / 60
        let durationStr = hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"

        // Extensions breakdown
        let extCounts = Dictionary(grouping: records, by: { $0.ext.lowercased() })
            .mapValues { $0.count }
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map { "\($0.key) (\($0.value))" }

        var lines: [String] = []
        lines.append("Files: \(records.count)")
        lines.append("Total Duration: \(durationStr)")
        lines.append("Media Size: \(mediaSize)")
        lines.append("Catalog Size: \(catSize)")
        if let date = target.lastScannedDate {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            lines.append("Last Scanned: \(fmt.string(from: date))")
        }

        lines.append("")
        lines.append("— Stream Types —")
        lines.append("Video + Audio: \(va)")
        lines.append("Video Only: \(vo)")
        lines.append("Audio Only: \(ao)")
        if noStreams > 0 { lines.append("No Streams: \(noStreams)") }

        if !extCounts.isEmpty {
            lines.append("")
            lines.append("— File Types —")
            lines.append(extCounts.joined(separator: ", "))
        }

        if !codecs.isEmpty {
            lines.append("")
            lines.append("— Video Codecs —")
            lines.append(codecs.sorted().joined(separator: ", "))
        }
        if !audioCodecs.isEmpty {
            lines.append("— Audio Codecs —")
            lines.append(audioCodecs.sorted().joined(separator: ", "))
        }
        if !containers.isEmpty {
            lines.append("— Containers —")
            lines.append(containers.sorted().joined(separator: ", "))
        }
        if !resolutions.isEmpty {
            lines.append("— Resolutions —")
            lines.append(resolutions.sorted().joined(separator: ", "))
        }

        // Error details
        if !failedRecs.isEmpty {
            lines.append("")
            lines.append("— Errors (\(failedRecs.count)) —")

            // Group by error reason (from isPlayable + notes)
            var reasonCounts: [String: Int] = [:]
            for rec in failedRecs {
                let reason: String
                if !rec.notes.isEmpty {
                    // Truncate long stderr to a recognizable prefix
                    let trimmed = rec.notes.prefix(80)
                    reason = String(trimmed)
                } else if !rec.isPlayable.isEmpty {
                    reason = rec.isPlayable
                } else {
                    reason = "Unknown error"
                }
                reasonCounts[reason, default: 0] += 1
            }
            for (reason, count) in reasonCounts.sorted(by: { $0.value > $1.value }).prefix(10) {
                lines.append("  \(count)x  \(reason)")
            }

            // Show a few example filenames
            let examples = failedRecs.prefix(5).map { $0.filename }
            lines.append("")
            lines.append("Example files:")
            for name in examples {
                lines.append("  \(name)")
            }
            if failedRecs.count > 5 {
                lines.append("  … and \(failedRecs.count - 5) more")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Build VolumeRow values from filtered scan targets for the Table.
    private var volumeTableRows: [VolumeRow] {
        filteredScanTargets.map { target in
            let recs = model.records.filter { $0.fullPath.hasPrefix(target.searchPath) }
            let errCount = recs.filter { $0.streamType == .ffprobeFailed }.count
            let bytes = recs.reduce(into: Int64(0)) { $0 += $1.sizeBytes }
            let isNet = VolumeReachability.isNetworkVolume(path: target.searchPath)
            let conn: String
            let connColor: Color
            if !target.isReachable {
                conn = "Offline"; connColor = .orange
            } else if isNet {
                conn = "Remote"; connColor = .purple
            } else {
                conn = "Connected"; connColor = .green
            }
            return VolumeRow(
                id: target.id,
                name: VolumeReachability.volumeName(forPath: target.searchPath),
                path: target.searchPath,
                status: target.status,
                connection: conn,
                connectionColor: connColor,
                files: recs.count,
                errors: errCount,
                mediaBytes: bytes,
                phase: target.phase,
                lastScanned: target.lastScannedDate,
                isReachable: target.isReachable,
                isNetwork: isNet,
                catalogStatusText: Self.buildCatalogStatus(records: recs, target: target)
            )
        }
    }

    /// Look up the CatalogScanTarget for a VolumeRow ID.
    private func target(for id: UUID) -> CatalogScanTarget? {
        model.scanTargets.first { $0.id == id }
    }

    private func browsePath(for target: CatalogScanTarget) {
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

    /// Targets that pass the current Volume Options filters.
    /// Always hides the RAM disk (VideoScan_Temp).
    private var filteredScanTargets: [CatalogScanTarget] {
        let base = model.scanTargets.filter {
            !$0.searchPath.contains("VideoScan_Temp")
        }

        // "All Ever Scanned" = show everything, no filtering
        if volumeFilters.contains(.allScanned) {
            return base
        }

        return base.filter { target in
            let path = target.searchPath
            let hasRecords = model.records.contains { $0.fullPath.hasPrefix(path) }
            let hasBadFiles = model.records.contains {
                $0.fullPath.hasPrefix(path) && $0.streamTypeRaw == StreamType.ffprobeFailed.rawValue
            }
            let isNetwork = VolumeReachability.isNetworkVolume(path: path)

            // Target passes if ANY active filter matches
            for filter in volumeFilters {
                switch filter {
                case .connected:
                    if target.isReachable { return true }
                case .network:
                    if isNetwork { return true }
                case .allScanned:
                    return true // handled above
                case .uncataloged:
                    if !hasRecords && target.isReachable { return true }
                case .withErrors:
                    if hasBadFiles { return true }
                }
            }
            return false
        }
    }

    // MARK: - Scan Targets Pane (matches PersonFinder's jobsSection pattern)

    private var scanTargetsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.title3).foregroundColor(.secondary)
                Text("Scan Volumes")
                    .font(.title3.weight(.semibold))
                    .padding(.trailing, 12)

                Button(action: { model.addScanTarget() }) {
                    Label("Local Volumes…", systemImage: "internaldrive")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: { showDiscoverVolumes = true }) {
                    Label("Network Volumes…", systemImage: "network")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Menu {
                    ForEach(VolumeFilter.allCases, id: \.self) { filter in
                        Button(action: { toggleVolumeFilter(filter) }) {
                            HStack {
                                if volumeFilters.contains(filter) {
                                    Image(systemName: "checkmark")
                                }
                                Label(filter.rawValue, systemImage: filter.icon)
                            }
                        }
                    }
                } label: {
                    Label("View", systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter which volumes appear in the list")

                Menu {
                    Section("Scan") {
                        Button(action: { model.startAllTargets() }) {
                            Label("Scan All Volumes", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.scanTargets.isEmpty)

                        ForEach(model.scanTargets.filter { $0.status.isIdle && $0.isReachable && !$0.searchPath.contains("VideoScan_Temp") }) { target in
                            Button(action: { model.startTarget(target) }) {
                                Label(VolumeReachability.volumeName(forPath: target.searchPath),
                                      systemImage: "play.fill")
                            }
                        }
                    }

                    Section("Delete") {
                        ForEach(model.scanTargets.filter { target in
                            model.records.contains { $0.fullPath.hasPrefix(target.searchPath) }
                        }) { target in
                            let count = model.records.filter { $0.fullPath.hasPrefix(target.searchPath) }.count
                            Button(role: .destructive, action: {
                                deleteVolumeCatalogTarget = target
                                showDeleteVolumeCatalogConfirm = true
                            }) {
                                Label("\(VolumeReachability.volumeName(forPath: target.searchPath)) (\(count))",
                                      systemImage: "trash")
                            }
                        }

                        Divider()

                        Button(role: .destructive, action: {
                            showDeleteAllCatalogConfirm = true
                        }) {
                            Label("Delete All (\(model.records.count))", systemImage: "trash.fill")
                        }
                        .disabled(model.records.isEmpty)
                    }
                } label: {
                    Label("Catalog Options", systemImage: "doc.text.magnifyingglass")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Update or delete catalog data")

                Button(action: { showVolumeCompare = true }) {
                    Label("Compare & Rescue", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Compare two volumes and copy unique media files from old drives to new ones")

                Spacer().frame(minWidth: 20)

                Button(action: { model.startAllTargets() }) {
                    Label("Scan All", systemImage: "play.fill")
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
                    Label("Stop All Scanning", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!model.hasActiveTargets)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if filteredScanTargets.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: model.scanTargets.isEmpty ? "externaldrive.badge.plus" : "line.3.horizontal.decrease.circle")
                        .font(.largeTitle).foregroundColor(.secondary)
                    Text(model.scanTargets.isEmpty ? "No scan volumes yet" : "No volumes match current filters")
                        .font(.headline).foregroundColor(.secondary)
                    Text(model.scanTargets.isEmpty
                         ? "Add volumes manually or use Discover to find mounted drives."
                         : "Try adjusting View filters to see more volumes.")
                        .font(.callout).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            } else {
                volumeTable
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .alert("Catalog Status — \(catalogStatusAlertTitle)", isPresented: $showCatalogStatusAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(catalogStatusAlertText)
        }
    }

    /// Auto-size the volume pane to fit all visible rows (header ~32 + ~30 per row),
    /// capped at 400 so it never swallows the entire window.
    private var scanTargetsPaneAutoHeight: CGFloat {
        let rowCount = CGFloat(volumeTableRows.count)
        return min(400, 32 + rowCount * 30)
    }

    // MARK: - Volume Table

    private var volumeTable: some View {
        Table(volumeTableRows, selection: $selectedVolumeIDs) {
            TableColumn("Volume") { row in
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundColor(volumeNameColor(for: row))
                        .lineLimit(1)
                        .help(row.path)
                }
            }
            .width(min: 100, ideal: 150)

            TableColumn("Status") { row in
                Text(row.connection)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(row.connectionColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(row.connectionColor.opacity(0.12))
                    )
            }
            .width(min: 70, ideal: 85)

            TableColumn("Files") { row in
                Text(row.files > 0 ? "\(row.files)" : "—")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .width(min: 50, ideal: 60)

            TableColumn("Errors") { row in
                if row.errors > 0 {
                    Text("\(row.errors)")
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundColor(.red)
                } else {
                    Text("—")
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .width(min: 50, ideal: 60)

            TableColumn("Media Size") { row in
                Text(row.mediaBytes > 0 ? Self.formatBytesStatic(row.mediaBytes) : "—")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Scanned") { row in
                if let date = row.lastScanned {
                    Text(Self.shortDateStatic(date))
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    Text("—")
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .width(min: 75, ideal: 95)

            TableColumn("Phase") { row in
                HStack(spacing: 4) {
                    if row.status.isActive {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                        Text("In Progress")
                            .font(.system(size: 15, weight: .medium))
                    } else {
                        Image(systemName: row.phase.icon)
                            .font(.system(size: 15))
                        Text(row.phase.rawValue)
                            .font(.system(size: 15))
                    }
                }
                .foregroundColor(row.status.isActive ? .orange : row.phase.color)
            }
            .width(min: 95, ideal: 115)

            TableColumn("") { row in
                HStack(spacing: 6) {
                    if let t = target(for: row.id) {
                        if t.status.isActive {
                            Button(action: { model.togglePauseTarget(t) }) {
                                Image(systemName: t.status.isPaused ? "play.fill" : "pause.fill")
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.borderless)
                            .help(t.status.isPaused ? "Resume" : "Pause")

                            Button(action: { model.stopTarget(t) }) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.borderless)
                            .help("Stop Scanning")
                        } else {
                            Button(action: { model.startTarget(t) }) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.borderless)
                            .disabled(t.searchPath.isEmpty || !t.isReachable)
                            .help(t.isReachable ? "Scan" : "Volume offline")
                        }
                    }
                }
            }
            .width(min: 55, ideal: 70)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            volumeContextMenu(for: ids)
        } primaryAction: { ids in
            // Double-click: filter catalog to that volume
            guard let id = ids.first, let t = target(for: id) else { return }
            if filterTargetPaths.contains(t.searchPath) {
                filterTargetPaths.remove(t.searchPath)
            } else {
                filterTargetPaths.insert(t.searchPath)
            }
        }
        .font(.system(size: 14))
    }

    @ViewBuilder
    private func volumeContextMenu(for ids: Set<UUID>) -> some View {
        let targets = ids.compactMap { id in target(for: id) }
        if let first = targets.first {
            let single = targets.count == 1

            Section("Catalog") {
                if single {
                    Button(action: {
                        catalogStatusAlertTitle = VolumeReachability.volumeName(forPath: first.searchPath)
                        let recs = model.records.filter { $0.fullPath.hasPrefix(first.searchPath) }
                        catalogStatusAlertText = Self.buildCatalogStatus(records: recs, target: first)
                        showCatalogStatusAlert = true
                    }) {
                        Label("Show Catalog Status", systemImage: "info.circle")
                    }
                }

                Button(action: {
                    for t in targets where t.status.isIdle && t.isReachable {
                        model.startTarget(t)
                    }
                }) {
                    Label(single ? "Scan / Update Catalog" : "Scan Selected", systemImage: "arrow.clockwise")
                }

                Button(role: .destructive, action: {
                    if single {
                        deleteVolumeCatalogTarget = first
                        showDeleteVolumeCatalogConfirm = true
                    } else {
                        for t in targets { model.deleteCatalogForTarget(t) }
                    }
                }) {
                    Label("Delete Catalog", systemImage: "trash")
                }

                if targets.contains(where: { $0.status == .complete || $0.status == .stopped || $0.status == .error }) {
                    Button(action: {
                        for t in targets { model.resetTarget(t) }
                    }) {
                        Label("Reset & Re-probe", systemImage: "arrow.counterclockwise")
                    }
                }
            }

            Divider()

            Section("Phase") {
                ForEach(VolumePhase.allCases, id: \.self) { phase in
                    Button(action: {
                        for t in targets { model.setPhase(phase, for: t) }
                    }) {
                        HStack {
                            if single, first.phase == phase {
                                Image(systemName: "checkmark")
                            }
                            Label(phase.rawValue, systemImage: phase.icon)
                        }
                    }
                }
            }

            Divider()

            Section("Volume") {
                if single {
                    Button(action: { browsePath(for: first) }) {
                        Label("Browse…", systemImage: "folder")
                    }
                    .disabled(!first.status.isIdle)
                }

                if targets.contains(where: { !$0.isReachable }) {
                    Button(action: {
                        for t in targets where !t.isReachable { model.wakeVolume(t) }
                    }) {
                        Label("Wake Volume", systemImage: "bolt.fill")
                    }
                }

                if targets.contains(where: { $0.isReachable && $0.searchPath.hasPrefix("/Volumes/") }) {
                    Button(action: {
                        for t in targets where t.isReachable && t.searchPath.hasPrefix("/Volumes/") {
                            model.ejectVolume(t)
                        }
                    }) {
                        Label("Eject", systemImage: "eject.fill")
                    }
                }

                Button(role: .destructive, action: {
                    for t in targets { model.removeScanTarget(t) }
                }) {
                    Label(single ? "Remove from List" : "Remove Selected", systemImage: "minus.circle")
                }
            }
        }
    }

    private func volumeNameColor(for row: VolumeRow) -> Color {
        switch row.status {
        case .scanning, .discovering: return .green
        case .paused:                 return .cyan
        case .complete:               return .blue
        case .error:                  return .red
        case .stopped:                return .orange
        case .idle:                   return .primary
        }
    }

    private static func formatBytesStatic(_ bytes: Int64) -> String {
        let mb: Int64 = 1_048_576
        let gb: Int64 = 1_073_741_824
        let tb: Int64 = 1_099_511_627_776
        if bytes < gb {
            return String(format: "%.1f MB", Double(bytes) / Double(mb))
        } else if bytes < tb {
            return String(format: "%.1f GB", Double(bytes) / Double(gb))
        } else {
            return String(format: "%.2f TB", Double(bytes) / Double(tb))
        }
    }

    private static func shortDateStatic(_ date: Date) -> String {
        let fmt = DateFormatter()
        let cal = Calendar.current
        if cal.component(.year, from: date) == cal.component(.year, from: Date()) {
            fmt.dateFormat = "MMM d"
        } else {
            fmt.dateFormat = "MMM d, yyyy"
        }
        return fmt.string(from: date)
    }
}

// MARK: - Toolbar (post-scan actions: correlate, combine, search, export)

private struct CatalogToolbar<Dashboard: View>: View {
    let isScanning: Bool
    let isCombining: Bool
    let isCorrelating: Bool
    let isAnalyzingDuplicates: Bool
    let correlateStatus: String
    let duplicateStatus: String
    let videoOnlyCount: Int
    let audioOnlyCount: Int
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
    let volumesWithDeletableDups: [(path: String, count: Int)]
    let onDeleteDuplicates: (String, Int) -> Void
    let onClearResults: () -> Void
    let onClearCache: () -> Void
    let onScanAvidBins: () -> Void
    let avidBinCount: Int
    let avidBinFiles: Int
    @Binding var showPairsOnly: Bool
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

            VStack(spacing: 2) {
                Menu {
                    Button("Correlate All", action: onCorrelateAll)
                    Button("Correlate Selected", action: onCorrelateSelected)
                        .disabled(selectedIDs.isEmpty)
                    Divider()
                    Toggle("Show Pairs Only", isOn: $showPairsOnly)
                        .disabled(!hasCorrelatedPairs)
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
                .disabled(isScanning || isCorrelating || !hasRecords)
                .help("Match video-only files with their corresponding audio-only files (e.g. Avid MXF pairs)")

                if !correlateStatus.isEmpty {
                    Text(correlateStatus)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(isCorrelating ? .secondary : .green)
                        .lineLimit(1)
                } else if videoOnlyCount > 0 || audioOnlyCount > 0 {
                    Text("\(videoOnlyCount)V + \(audioOnlyCount)A candidates")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 120)

            VStack(spacing: 2) {
                Menu {
                    Button("Analyze All", action: onAnalyzeDuplicatesAll)
                    Button("Analyze Selected", action: onAnalyzeDuplicatesSelected)
                        .disabled(selectedIDs.isEmpty)

                    if !volumesWithDeletableDups.isEmpty {
                        Divider()
                        Menu("Delete Duplicates on Volume…") {
                            ForEach(volumesWithDeletableDups, id: \.path) { vol in
                                Button("\(URL(fileURLWithPath: vol.path).lastPathComponent) — \(vol.count) file\(vol.count == 1 ? "" : "s")") {
                                    onDeleteDuplicates(vol.path, vol.count)
                                }
                            }
                        }
                    }
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
                .disabled(isScanning || isAnalyzingDuplicates || !hasRecords)
                .help("Find duplicate files by comparing hash, duration, filename, resolution, and other signals")

                if !duplicateStatus.isEmpty {
                    Text(duplicateStatus)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(isAnalyzingDuplicates ? .secondary : .yellow)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 120)

            VStack(spacing: 2) {
                Button(action: onScanAvidBins) {
                    HStack(spacing: 4) {
                        Label("Avid Bins", systemImage: "film.stack")
                        if avidBinCount > 0 {
                            Text("\(avidBinCount) clips")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isScanning)
                .help("Scan for Avid .avb bin files and extract clip metadata — badge shows total clips found across all bins")

                if avidBinFiles > 0 {
                    Text("\(avidBinFiles) bins · \(avidBinCount) clips")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.cyan)
                        .lineLimit(1)
                }
            }

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
                TextField("Search files, codecs, notes…", text: $searchText)
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
                settingsHeader

                Divider()

                // Scanning section
                VStack(alignment: .leading, spacing: 16) {
                    Label("Scanning", systemImage: "magnifyingglass")
                        .font(.headline)
                        .foregroundColor(.blue)

                    settingRow(
                        title: "Probes per volume",
                        value: "\(settings.probesPerVolume)",
                        description: "Concurrent ffprobe processes per volume",
                        slider: Slider(value: Binding(
                            get: { Double(settings.probesPerVolume) },
                            set: { settings.probesPerVolume = Int($0) }
                        ), in: 1...32, step: 1),
                        accentColor: .blue
                    )

                    settingRow(
                        title: "Memory floor",
                        value: "\(settings.memoryFloorGB) GB",
                        valueColor: floorColor(settings.memoryFloorGB),
                        description: "Auto-pause scanning when free RAM drops below this",
                        slider: Slider(value: Binding(
                            get: { Double(settings.memoryFloorGB) },
                            set: { settings.memoryFloorGB = Int($0) }
                        ), in: 1...Double(max(1, totalRAMGB / 4)), step: 1),
                        accentColor: .blue
                    )
                }

                Divider()

                // Network section
                VStack(alignment: .leading, spacing: 16) {
                    Label("Network Volumes", systemImage: "network")
                        .font(.headline)
                        .foregroundColor(.mint)

                    settingRow(
                        title: "RAM disk size",
                        value: "\(settings.ramDiskGB) GB",
                        valueColor: ramDiskColor(settings.ramDiskGB),
                        description: "Temporary RAM disk for network file prefetch (mounted at /Volumes/VideoScan_Temp)",
                        slider: Slider(value: Binding(
                            get: { Double(settings.ramDiskGB) },
                            set: { settings.ramDiskGB = Int($0) }
                        ), in: 1...Double(max(1, totalRAMGB / 2)), step: 1),
                        accentColor: .mint
                    )

                    settingRow(
                        title: "Prefetch size",
                        value: "\(settings.prefetchMB) MB",
                        description: "Header bytes copied per network file before probing",
                        slider: Slider(value: Binding(
                            get: { Double(settings.prefetchMB) },
                            set: { settings.prefetchMB = Int($0) }
                        ), in: 10...200, step: 10),
                        accentColor: .mint
                    )
                }

                Divider()

                // Video Combiner section
                VStack(alignment: .leading, spacing: 16) {
                    Label("Video Combiner", systemImage: "arrow.triangle.merge")
                        .font(.headline)
                        .foregroundColor(.orange)

                    settingRow(
                        title: "Concurrent tasks",
                        value: "\(settings.combineConcurrency)",
                        description: "Parallel ffmpeg processes for combining video + audio pairs",
                        slider: Slider(value: Binding(
                            get: { Double(settings.combineConcurrency) },
                            set: { settings.combineConcurrency = Int($0) }
                        ), in: 1...16, step: 1),
                        accentColor: .orange
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

    // MARK: - Settings Header (chip + RAM info)

    private var settingsHeader: some View {
        let info = Self.chipInfo()
        let freeGB = Int(MemoryPressureMonitor.shared.availableMemory() / (1024 * 1024 * 1024))
        let freeColor: Color = freeGB < 4 ? .red : freeGB < 8 ? .yellow : .green
        return VStack(alignment: .leading, spacing: 10) {
            Text("Performance Settings")
                .font(.title2.weight(.semibold))
            HStack {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.blue)
                Text(info.name)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                Spacer()
                chipTile("\(info.pCores)", label: "P-cores", color: .blue, icon: "bolt.fill")
                Spacer()
                chipTile("\(info.eCores)", label: "E-cores", color: .green, icon: "leaf.fill")
                Spacer()
                if info.gpuCores > 0 {
                    chipTile("\(info.gpuCores)", label: "GPU", color: .purple, icon: "gpu")
                    Spacer()
                }
                if info.neuralCores > 0 {
                    chipTile("\(info.neuralCores)", label: "Neural", color: .orange, icon: "brain")
                    Spacer()
                }
                // RAM tile — unified: total on top, free below
                VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 3) {
                            Image(systemName: "memorychip")
                                .font(.system(size: 10))
                            Text("\(totalRAMGB) GB RAM")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(.cyan)
                        HStack(spacing: 3) {
                            Image(systemName: "memorychip")
                                .font(.system(size: 10))
                                .hidden()
                            Text("\(freeGB) GB Free")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(freeColor)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.cyan.opacity(0.10))
                    .cornerRadius(6)
            }
        }
    }

    private func chipTile(_ value: String, label: String, color: Color, icon: String) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
            }
            Text(label)
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.10))
        .cornerRadius(6)
    }

    private struct ChipInfo {
        let name: String
        let pCores: Int
        let eCores: Int
        let gpuCores: Int
        let neuralCores: Int
    }

    private static func chipInfo() -> ChipInfo {
        func sysctl(_ key: String) -> Int {
            var val: Int = 0
            var size = MemoryLayout<Int>.size
            sysctlbyname(key, &val, &size, nil, 0)
            return val
        }

        func sysctlString(_ key: String) -> String {
            var size = 0
            sysctlbyname(key, nil, &size, nil, 0)
            guard size > 0 else { return "" }
            var buf = [CChar](repeating: 0, count: size)
            sysctlbyname(key, &buf, &size, nil, 0)
            return String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let name = sysctlString("machdep.cpu.brand_string")
            .replacingOccurrences(of: "Apple ", with: "")

        // perflevel0 = Performance cores, perflevel1 = Efficiency cores
        let pCores = sysctl("hw.perflevel0.physicalcpu")
        let eCores = sysctl("hw.perflevel1.physicalcpu")

        // GPU core count from IORegistry
        var gpuCores = 0
        let matchDict = IOServiceMatching("AGXAccelerator")
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator) == KERN_SUCCESS {
            var entry = IOIteratorNext(iterator)
            while entry != 0 {
                if let prop = IORegistryEntryCreateCFProperty(entry, "gpu-core-count" as CFString, kCFAllocatorDefault, 0) {
                    gpuCores = (prop.takeRetainedValue() as? Int) ?? 0
                }
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }

        // Neural Engine: not exposed via sysctl, derive from chip model
        let neuralCores = Self.neuralCoresForChip(name)

        return ChipInfo(name: name, pCores: pCores, eCores: eCores,
                        gpuCores: gpuCores, neuralCores: neuralCores)
    }

    private static func neuralCoresForChip(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower.contains("m4")  { return 16 }
        if lower.contains("m3")  { return 16 }
        if lower.contains("m2")  { return 16 }
        if lower.contains("m1")  { return 16 }
        return 0
    }

    private func settingRow(
        title: String,
        value: String,
        valueColor: Color = .secondary,
        description: String,
        slider: some View,
        accentColor: Color = .accentColor
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
                .tint(accentColor)
            Text(description)
                .font(.footnote).foregroundColor(.secondary)
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
    let showPairsOnly: Bool
    let previewImage: NSImage?
    let previewFilename: String
    let previewOfflineVolumeName: String?
    @Binding var showInspector: Bool
    let onSort: ([KeyPathComparator<VideoRecord>]) -> Void
    let onSelect: (UUID?) -> Void
    let onClearPreview: () -> Void
    var onCombinePair: ((VideoRecord, VideoRecord) -> Void)? = nil

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var showRenameSheet = false
    @State private var renameTarget: VideoRecord?
    @State private var renameText: String = ""

    /// Stable snapshot the Table reads from. Decoupled from `records` so the
    /// Table never sees the data array mutate mid-gesture (which races with
    /// AppKit's canDragRows / mouseDown handling and crashes inside
    /// ForEach.IDGenerator with an out-of-bounds subscript).
    @State private var tableData: [VideoRecord] = []

    private var selectedRecord: VideoRecord? {
        guard let id = selectedIDs.first else { return nil }
        return records.first(where: { $0.id == id })
    }

    /// All records sharing the selected record's duplicate group (excluding the selected record itself)
    private var duplicateGroupMembers: [VideoRecord] {
        guard let rec = selectedRecord,
              let groupID = rec.duplicateGroupID else { return [] }
        return records.filter { $0.duplicateGroupID == groupID && $0.id != rec.id }
    }

    private func volumeRoot(for path: String) -> String {
        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/", maxSplits: 3)
            if parts.count >= 2 { return "/Volumes/" + String(parts[1]) }
        }
        return "/"
    }

    private func volumeDiskSize(path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let total = attrs[.systemSize] as? Int64, total > 0 else { return "" }
        return formatBytes(total)
    }

    private func mediaOnVolume(path: String) -> String {
        let bytes = records.filter { $0.fullPath.hasPrefix(path) }
            .reduce(into: Int64(0)) { $0 += $1.sizeBytes }
        guard bytes > 0 else { return "0 MB" }
        return formatBytes(bytes)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let kb: Int64 = 1_024
        let mb: Int64 = 1_048_576
        let gb: Int64 = 1_073_741_824
        let tb: Int64 = 1_099_511_627_776
        if bytes < mb {
            return String(format: "%.0f KB", Double(bytes) / Double(kb))
        } else if bytes < gb {
            return String(format: "%.1f MB", Double(bytes) / Double(mb))
        } else if bytes < tb {
            return String(format: "%.1f GB", Double(bytes) / Double(gb))
        } else {
            return String(format: "%.2f TB", Double(bytes) / Double(tb))
        }
    }

    private func computeFiltered() -> [VideoRecord] {
        var out = records
        if !filterTargetPaths.isEmpty {
            let prefixes = Array(filterTargetPaths)
            out = out.filter { rec in
                prefixes.contains(where: { rec.fullPath.hasPrefix($0) })
            }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            out = out.filter {
                $0.filename.lowercased().contains(q) ||
                $0.directory.lowercased().contains(q) ||
                $0.streamTypeRaw.lowercased().contains(q) ||
                $0.isPlayable.lowercased().contains(q) ||
                $0.notes.lowercased().contains(q) ||
                $0.videoCodec.lowercased().contains(q) ||
                $0.duplicateDisposition.rawValue.lowercased().contains(q) ||
                $0.duplicateBestMatchFilename.lowercased().contains(q) ||
                $0.duplicateReasons.lowercased().contains(q)
            }
        }
        if showPairsOnly {
            // Only show records that have a correlated partner
            let pairedIDs = Set(out.compactMap { $0.pairedWith != nil ? $0.id : nil })
            let partnerIDs = Set(out.compactMap { $0.pairedWith?.id })
            let allPairIDs = pairedIDs.union(partnerIDs)
            out = out.filter { allPairIDs.contains($0.id) }

            // Collect video records (one per pair), sort by current table sort
            var videos = out.filter { $0.streamType == .videoOnly && $0.pairedWith != nil }
            videos.sort(using: sortOrder)

            // Flatten: video then its audio partner, in sort order
            var result: [VideoRecord] = []
            for v in videos {
                result.append(v)
                if let a = v.pairedWith { result.append(a) }
            }
            out = result
        }
        return out
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
                    duplicateGroupMembers: duplicateGroupMembers,
                    previewImage: previewImage,
                    previewOfflineVolumeName: previewOfflineVolumeName,
                    onSelectRecord: { id in
                        selectedIDs = [id]
                        onSelect(id)
                    }
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
        .sheet(isPresented: $showRenameSheet) {
            RenameSheet(
                filename: $renameText,
                originalExt: (renameTarget?.filename as NSString?)?.pathExtension ?? "",
                onConfirm: { performRename() },
                onCancel: { showRenameSheet = false }
            )
        }
    }

    private func performRename() {
        guard let rec = renameTarget else { return }
        let ext = (rec.filename as NSString).pathExtension
        let newFilename = renameText.trimmingCharacters(in: .whitespaces) + "." + ext
        guard newFilename != rec.filename, !renameText.isEmpty else {
            showRenameSheet = false
            return
        }

        let oldPath = rec.fullPath
        let dir = (oldPath as NSString).deletingLastPathComponent
        let newPath = (dir as NSString).appendingPathComponent(newFilename)

        // Check destination doesn't already exist
        guard !FileManager.default.fileExists(atPath: newPath) else {
            showRenameSheet = false
            return
        }

        do {
            try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
            // Update the catalog record in-place
            rec.filename = newFilename
            rec.fullPath = newPath
            // Trigger table refresh
            tableData = computeFiltered()
        } catch {
            // Silent fail — file may be on offline volume or locked
        }
        showRenameSheet = false
    }

    // MARK: - Results Table

    private var catalogTable: some View {
        Table(tableData, selection: $selectedIDs, sortOrder: $sortOrder) {
            TableColumn("Filename", value: \.filename) { rec in
                HStack(spacing: 4) {
                    if showPairsOnly && rec.pairedWith != nil {
                        Image(systemName: rec.streamType == .videoOnly ? "film" : "waveform")
                            .font(.system(size: 10))
                            .foregroundColor(rec.streamType == .videoOnly ? .blue : .green)
                    }
                    Text(rec.filename)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(showPairsOnly && rec.pairedWith != nil
                            ? (rec.streamType == .videoOnly ? .blue : .green)
                            : .primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .help(rec.directory)
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

                Button("Rename…") {
                    renameTarget = rec
                    renameText = (rec.filename as NSString).deletingPathExtension
                    showRenameSheet = true
                }

                // Show copies / duplicates
                let copies = records.filter {
                    $0.id != rec.id && $0.duplicateGroupID != nil && $0.duplicateGroupID == rec.duplicateGroupID
                }
                if !copies.isEmpty {
                    Menu("Copies (\(copies.count))") {
                        ForEach(copies) { dup in
                            Button("\(dup.filename) — \(VolumeReachability.volumeName(forPath: dup.fullPath))") {
                                selectedIDs = [dup.id]
                                onSelect(dup.id)
                            }
                        }
                    }
                }

                if let partner = rec.pairedWith {
                    Divider()
                    Button(rec.streamType == .videoOnly ? "Find Matched Audio" : "Find Matched Video") {
                        selectedIDs = [partner.id]
                        onSelect(partner.id)
                    }
                    Button("Combine This Pair…") {
                        let video = rec.streamType == .videoOnly ? rec : partner
                        let audio = rec.streamType == .audioOnly ? rec : partner
                        onCombinePair?(video, audio)
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
        .onChange(of: showPairsOnly)     { tableData = computeFiltered() }
    }

    // MARK: - Preview / Player

    private var previewPlayer: some View {
        Group {
            if selectedRecord != nil {
                HStack(spacing: 0) {
                    // Volume info — lower left
                    if let rec = selectedRecord {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Image(systemName: "externaldrive.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.accentColor)
                                Text(VolumeReachability.volumeName(forPath: rec.fullPath))
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                if !VolumeReachability.isReachable(path: rec.fullPath) {
                                    Text("OFFLINE")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(.orange)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                                }
                            }
                            // Volume size + media cataloged
                            VStack(alignment: .leading, spacing: 2) {
                                let volPath = volumeRoot(for: rec.fullPath)
                                let volSize = volumeDiskSize(path: volPath)
                                if !volSize.isEmpty {
                                    Text("Volume Size: \(volSize)")
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                let mediaSize = mediaOnVolume(path: volPath)
                                Text("Media Cataloged: \(mediaSize)")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            if isPlaying {
                                Button {
                                    player?.pause()
                                    player = nil
                                    isPlaying = false
                                } label: {
                                    Label("Stop", systemImage: "stop.fill")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .padding(.top, 4)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Media preview — center
                    VStack(spacing: 0) {
                        if previewOfflineVolumeName != nil
                            || (selectedRecord != nil && !VolumeReachability.isReachable(path: selectedRecord!.fullPath)) {
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
                        } else if isPlaying, let player = player {
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
                        } else if selectedRecord?.streamType == .audioOnly {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.black)
                                VStack(spacing: 6) {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 36))
                                        .foregroundColor(.yellow.opacity(0.7))
                                    Text("AUDIO ONLY")
                                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                                        .foregroundColor(.yellow)
                                }
                            }
                            .frame(maxWidth: 480, maxHeight: 180)
                            .aspectRatio(16.0/9.0, contentMode: .fit)
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.gray.opacity(0.1))
                                    .frame(width: 240, height: 135)
                                ProgressView()
                            }
                        }
                    }

                    // Balance — right side
                    Spacer()
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("Select a file to preview")
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

// MARK: - Rename Sheet

private struct RenameSheet: View {
    @Binding var filename: String
    let originalExt: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename File")
                .font(.headline)
            HStack {
                TextField("New name", text: $filename)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text(".\(originalExt)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(filename.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

// MARK: - Inspector Panel

private struct InspectorPanel: View {
    let record: VideoRecord?
    let duplicateGroupMembers: [VideoRecord]
    let previewImage: NSImage?
    let previewOfflineVolumeName: String?
    var onSelectRecord: ((UUID) -> Void)? = nil

    var body: some View {
        if let rec = record {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Filename header
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rec.filename)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .padding(.top, 12)
                        HStack(spacing: 8) {
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
                        // Volume name — prominent
                        HStack(spacing: 4) {
                            Image(systemName: "externaldrive.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.accentColor)
                            Text(VolumeReachability.volumeName(forPath: rec.fullPath))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                        }
                        .padding(.top, 2)
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
                                HStack(alignment: .top, spacing: 6) {
                                    Text("Paired With")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .frame(width: 80, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Button {
                                            onSelectRecord?(paired.id)
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: paired.streamType == .audioOnly
                                                      ? "waveform" : "film")
                                                    .font(.system(size: 9))
                                                Text(paired.filename)
                                                    .font(.system(size: 11, weight: .medium))
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                            .foregroundColor(.accentColor)
                                        }
                                        .buttonStyle(.plain)
                                        .onHover { hovering in
                                            if hovering {
                                                NSCursor.pointingHand.push()
                                            } else {
                                                NSCursor.pop()
                                            }
                                        }
                                        Text(paired.directory)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                    }
                                    Spacer()
                                }
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

                            // Show all copies in this duplicate group
                            if !duplicateGroupMembers.isEmpty {
                                let thisVolume = VolumeReachability.volumeName(forPath: rec.fullPath)

                                Divider().padding(.vertical, 4)

                                Text("All Copies (\(duplicateGroupMembers.count + 1) total)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .padding(.leading, 4)

                                // This record (selected)
                                duplicateCopyRow(
                                    filename: rec.filename,
                                    volumeName: thisVolume,
                                    directory: (rec.fullPath as NSString).deletingLastPathComponent,
                                    disposition: rec.duplicateDisposition,
                                    isSameVolume: true,
                                    isSelected: true
                                )

                                // Other group members
                                ForEach(duplicateGroupMembers, id: \.id) { member in
                                    let memberVolume = VolumeReachability.volumeName(forPath: member.fullPath)
                                    let sameVolume = (memberVolume == thisVolume)
                                    duplicateCopyRow(
                                        filename: member.filename,
                                        volumeName: memberVolume,
                                        directory: (member.fullPath as NSString).deletingLastPathComponent,
                                        disposition: member.duplicateDisposition,
                                        isSameVolume: sameVolume,
                                        isSelected: false
                                    )
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

                    if !rec.notes.isEmpty {
                        inspectorSection("Notes", systemImage: "exclamationmark.bubble") {
                            Text(rec.notes)
                                .font(.system(size: 12))
                                .foregroundColor(rec.streamType == .ffprobeFailed ? .red : .secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - Duplicate Copy Row

    @ViewBuilder
    private func duplicateCopyRow(
        filename: String,
        volumeName: String,
        directory: String,
        disposition: DuplicateDisposition,
        isSameVolume: Bool,
        isSelected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle()
                    .fill(disposition.textColor)
                    .frame(width: 6, height: 6)
                Text(filename)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isSelected {
                    Text("(selected)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 4) {
                Image(systemName: isSameVolume ? "internaldrive" : "externaldrive")
                    .font(.system(size: 9))
                    .foregroundColor(isSameVolume ? .secondary : .orange)
                Text(volumeName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isSameVolume ? .secondary : .orange)
                if !isSameVolume {
                    Text("(different volume)")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                }
            }
            Text(directory)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
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

// MARK: - Discover Volumes Sheet

private struct DiscoverVolumesSheet: View {
    @ObservedObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    @State private var volumes: [DiscoveredVolume] = []
    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "network")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Discover Volumes")
                        .font(.headline)
                    Text("Mounted local and network volumes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            if volumes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No volumes found")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Mount a drive or network share and click Refresh.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(volumes, selection: $selected) { vol in
                    HStack(spacing: 10) {
                        Image(systemName: vol.isNetwork ? "network" : "internaldrive")
                            .font(.title3)
                            .foregroundColor(vol.isNetwork ? .blue : .secondary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(vol.name)
                                    .font(.system(size: 13, weight: .semibold))
                                if vol.isNetwork {
                                    Text("Network")
                                        .font(.system(size: 9, weight: .medium))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.blue.opacity(0.15))
                                        .cornerRadius(3)
                                        .foregroundColor(.blue)
                                }
                                if vol.alreadyAdded {
                                    Text("Already added")
                                        .font(.system(size: 9, weight: .medium))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.green.opacity(0.15))
                                        .cornerRadius(3)
                                        .foregroundColor(.green)
                                }
                            }
                            Text(vol.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            if vol.totalBytes > 0 {
                                Text("\(vol.usedFormatted) used of \(vol.totalFormatted)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .tag(vol.id)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            Divider()

            // Footer
            HStack {
                Text("\(volumes.count) volume(s) found")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Selected (\(selected.count))") {
                    let toAdd = volumes.filter { selected.contains($0.id) && !$0.alreadyAdded }
                    model.addDiscoveredVolumes(toAdd)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 550, height: 420)
        .onAppear { refresh() }
    }

    private func refresh() {
        volumes = model.discoverVolumes()
        selected = []
    }
}
