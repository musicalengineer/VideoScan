import SwiftUI

// MARK: - Root (Tab switcher)

struct ContentView: View {
    @EnvironmentObject var model: VideoScanModel
    @StateObject private var personFinderModel = PersonFinderModel()
    @AppStorage("selectedTab") private var selectedTab: Int = 0
    private let tabFontSize: Double = 18

    private let tabs: [(label: String, icon: String, tag: Int)] = [
        ("People", "person.2.fill", 0),
        ("Media", "film.stack", 1)
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
    /// the catalog table. Derived from `selectedVolumeIDs` so that selecting
    /// a volume row (single-click) filters the catalog to that volume, and
    /// multi-select (Cmd-click or Shift-click) expands the filter. Empty
    /// selection = show all volumes.
    private var filterTargetPaths: Set<String> {
        Set(selectedVolumeIDs.compactMap { target(for: $0)?.searchPath })
    }
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
    /// Opens an independent resizable window keyed by CatalogInfoItem value.
    /// Defined as a `WindowGroup(for:)` scene in VideoScanApp.
    @Environment(\.openWindow) private var openWindow

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

    /// Open the Catalog Info window for a given target. Shared by the
    /// right-click menu Button and the Cmd-I global shortcut. Window identity
    /// is the volume path, so repeat invocations focus the existing window
    /// rather than stacking duplicates.
    private func showCatalogInfo(for target: CatalogScanTarget) {
        let volName = VolumeReachability.volumeName(forPath: target.searchPath)
        let recs = model.records.filter { $0.fullPath.hasPrefix(target.searchPath) }
        let item = CatalogInfoItem(
            volumePath: target.searchPath,
            title: "Catalog Info — \(volName)",
            message: Self.buildCatalogInfo(records: recs, target: target)
        )
        openWindow(value: item)
    }

    /// Cmd-I handler: resolves the volume-table selection to a target and
    /// opens Catalog Info. Requires exactly one row selected.
    private func showCatalogInfoForSelection() {
        guard selectedVolumeIDs.count == 1,
              let id = selectedVolumeIDs.first,
              let t = target(for: id) else { return }
        showCatalogInfo(for: t)
    }

    /// Single-window "Catalog Info" builder: combines provenance (where/when/
    /// how the catalog was captured — from ScanContext) with the catalog
    /// content summary (counts, sizes, codecs, errors). Sections are separated
    /// by bold rules so the resizable sheet reads like a printable report.
    static func buildCatalogInfo(records: [VideoRecord], target: CatalogScanTarget) -> String {
        guard !records.isEmpty else { return "No catalog data for this volume." }

        var lines: [String] = []
        let rule = String(repeating: "━", count: 48)

        // ══════════════════════════════════════════════════════════
        // Section 1 — PROVENANCE (where/when/how this catalog was made)
        // ══════════════════════════════════════════════════════════
        let populated = records.filter { $0.scanContext.isPopulated }
        let unpopulated = records.count - populated.count

        lines.append(rule)
        lines.append("  PROVENANCE")
        lines.append(rule)
        lines.append("Volume Path: \(target.searchPath)")
        lines.append("Records: \(records.count) (with provenance: \(populated.count), without: \(unpopulated))")

        if populated.isEmpty {
            lines.append("")
            lines.append("No scan-provenance data has been captured yet.")
            lines.append("Rescan this volume to populate scan host, mount type,")
            lines.append("volume UUID, and remote-server fields.")
        } else {
            let hosts       = Set(populated.map { $0.scanContext.scanHost }.filter { !$0.isEmpty })
            let mountTypes  = Set(populated.map { $0.scanContext.volumeMountType }.filter { !$0.isEmpty })
            let uuids       = Set(populated.map { $0.scanContext.volumeUUID }.filter { !$0.isEmpty })
            let remoteHosts = Set(populated.map { $0.scanContext.remoteServerName }.filter { !$0.isEmpty })

            lines.append("Scanned By: \(hosts.isEmpty ? "(unknown)" : hosts.sorted().joined(separator: ", "))")
            lines.append("Mount Type: \(mountTypes.isEmpty ? "(unknown)" : mountTypes.sorted().joined(separator: ", "))")
            if !remoteHosts.isEmpty {
                lines.append("Remote Server: \(remoteHosts.sorted().joined(separator: ", "))")
            }
            if uuids.isEmpty {
                lines.append("Volume UUID: (none — filesystem did not vend one)")
            } else if uuids.count == 1 {
                lines.append("Volume UUID: \(uuids.first!)")
            } else {
                lines.append("Volume UUID: \(uuids.count) distinct UUIDs seen:")
                for u in uuids.sorted() { lines.append("  \(u)") }
            }

            let scanDates = populated.compactMap { $0.scanContext.scannedAt }
            if let earliest = scanDates.min(), let latest = scanDates.max() {
                let fmt = DateFormatter()
                fmt.dateStyle = .medium
                fmt.timeStyle = .short
                if earliest == latest {
                    lines.append("Scan Time: \(fmt.string(from: earliest))")
                } else {
                    lines.append("Scan Time Range: \(fmt.string(from: earliest)) → \(fmt.string(from: latest))")
                }
            }

            if unpopulated > 0 {
                lines.append("")
                lines.append("Note: \(unpopulated) record(s) predate provenance capture — rescan to backfill.")
            }
        }

        // ══════════════════════════════════════════════════════════
        // Section 2 — CATALOG SUMMARY (what's in the catalog)
        // ══════════════════════════════════════════════════════════
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

        lines.append("")
        lines.append(rule)
        lines.append("  CATALOG SUMMARY")
        lines.append(rule)
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
                catalogStatusText: Self.buildCatalogInfo(records: recs, target: target)
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

                ScanOptionsMenu(model: model)

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
                    if model.hasPausedTargets { model.resumeAllTargets() } else { model.pauseAllTargets() }
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
        .background(
            // Hidden button gives Cmd-I a global binding on the scan-volumes
            // pane — the context-menu Button's shortcut only fires when the
            // menu is actually open, so this mirrors it for the selected row.
            Button("") { showCatalogInfoForSelection() }
                .keyboardShortcut("i", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
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
                    Button(action: { showCatalogInfo(for: first) }) {
                        Label("Catalog Info", systemImage: "info.circle")
                    }
                    .keyboardShortcut("i", modifiers: .command)
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

/// Payload for the Catalog Info window. Codable/Hashable so it can back a
/// `WindowGroup(for:)` scene — SwiftUI uses the value for window identity
/// and session restoration, so two different volumes produce two distinct
/// windows.
struct CatalogInfoItem: Identifiable, Codable, Hashable {
    /// Stable id — using the volume path means re-invoking Catalog Info on
    /// the same volume focuses the existing window instead of stacking
    /// duplicates. A fresh UUID would open a new window every click.
    var id: String { volumePath }
    let volumePath: String
    let title: String
    let message: String
}

/// Contents of the Catalog Info window. Independent resizable AppKit window
/// (not a sheet) so Rick can drag edges freely, keep it open while working,
/// or compare two volumes side by side.
struct CatalogInfoWindow: View {
    let item: CatalogInfoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.title)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                Text(item.message)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }

            Divider()

            HStack {
                Spacer()
                Button("Copy") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(item.message, forType: .string)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}
