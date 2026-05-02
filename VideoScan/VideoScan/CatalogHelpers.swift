// CatalogHelpers.swift
// Catalog tab helper views: toolbar, content table, inspector, rename sheet,
// discover-volumes sheet.

import SwiftUI
import AVKit

// MARK: - Toolbar (post-scan actions: correlate, combine, search, export)

struct CatalogToolbar<Dashboard: View>: View {
    @EnvironmentObject var model: VideoScanModel
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
    let onCorrelateAcrossVolumes: () -> Void
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
    @Binding var viewFilters: Set<CatalogViewFilter>
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
                    Button("Find A/V Pairs Across Volumes", action: onCorrelateAcrossVolumes)
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
                CatalogScanWindowController.shared.show(dashboard: dashboard, model: model)
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

            Menu {
                ForEach(CatalogViewFilter.allCases, id: \.self) { filter in
                    Toggle(isOn: Binding(
                        get: { viewFilters.contains(filter) },
                        set: { on in
                            if on { viewFilters.insert(filter) }
                            else  { viewFilters.remove(filter) }
                        }
                    )) {
                        Label(filter.rawValue, systemImage: filter.icon)
                    }
                }
                if !viewFilters.isEmpty {
                    Divider()
                    Button("Clear All Filters") { viewFilters.removeAll() }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "line.3.horizontal.decrease.circle\(viewFilters.isEmpty ? "" : ".fill")")
                    Text("View")
                }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 70)
            .help("Filter catalog results")

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

// MARK: - Table + Preview + Inspector

struct CatalogContent: View {
    @EnvironmentObject var model: VideoScanModel
    let records: [VideoRecord]
    @Binding var selectedIDs: Set<UUID>
    @Binding var sortOrder: [KeyPathComparator<VideoRecord>]
    let searchText: String
    let filterTargetPaths: Set<String>
    let showPairsOnly: Bool
    let viewFilters: Set<CatalogViewFilter>
    /// When non-empty, show only these specific records (overrides all other filters).
    /// Used by Archive tab's "Show in Catalog" / "Show Pair in Catalog".
    var filterByIDs: Set<UUID> = []
    /// When `filterByIDs` was populated by an on-demand "Find A/V Pair", carries
    /// the score so the focus banner can show a Best/Better/Good/Maybe label.
    /// nil for filters from other sources (Archive, already-paired).
    var focusMatchScore: Int?
    let previewImage: NSImage?
    let previewFilename: String
    let previewOfflineVolumeName: String?
    @Binding var showInspector: Bool
    let onSort: ([KeyPathComparator<VideoRecord>]) -> Void
    let onSelect: (UUID?) -> Void
    let onClearPreview: () -> Void
    var onCombinePair: ((VideoRecord, VideoRecord) -> Void)?
    var onShowPair: ((UUID, UUID) -> Void)?
    var onFindAVPair: ((VideoRecord) -> Void)?
    var onClearFilter: (() -> Void)?

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var showRenameSheet = false
    @State private var renameTarget: VideoRecord?
    @State private var renameText: String = ""
    @State private var showNotesSheet = false
    @State private var notesTarget: VideoRecord?
    @State private var notesText: String = ""

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
        // ID filter overrides everything — used by Archive "Show in Catalog"
        if !filterByIDs.isEmpty {
            return records.filter { filterByIDs.contains($0.id) }
        }
        var out = records
        if !filterTargetPaths.isEmpty {
            let prefixes = Array(filterTargetPaths)
            out = out.filter { rec in
                prefixes.contains(where: { rec.fullPath.hasPrefix($0) })
            }
        }
        if !searchText.isEmpty {
            // Filename-only search (Finder-like). Users searching "matt" expect
            // files literally named *matt*, not files that happen to live in a
            // "Matthew" directory or have "matte" appear in some codec note.
            let q = searchText.lowercased()
            out = out.filter { $0.filename.lowercased().contains(q) }
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
        // View menu filters (additive — each active filter narrows further)
        if viewFilters.contains(.onlineOnly) {
            out = out.filter { VolumeReachability.isReachable(path: $0.fullPath) }
        }
        if viewFilters.contains(.videoAndAudioOnly) {
            out = out.filter { $0.streamType == .videoAndAudio }
        }
        if viewFilters.contains(.unpairedOnly) {
            out = out.filter {
                ($0.streamType == .videoOnly || $0.streamType == .audioOnly) && $0.pairedWith == nil
            }
        }
        if viewFilters.contains(.ratedOnly) {
            out = out.filter { $0.starRating > 0 }
        }
        return out
    }

    var body: some View {
        HSplitView {
            // MARK: Left side — Table + Player
            VSplitView {
                VStack(spacing: 0) {
                    if !filterByIDs.isEmpty {
                        pairFilterBanner
                    }
                    catalogTable
                }
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
        .sheet(isPresented: $showNotesSheet) {
            NotesSheet(
                notes: $notesText,
                filename: notesTarget?.filename ?? "",
                onConfirm: {
                    notesTarget?.notes = notesText
                    model.saveCatalogDebounced()
                    showNotesSheet = false
                },
                onCancel: { showNotesSheet = false }
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

    private var pairFilterBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.horizontal.3.decrease.circle.fill")
                .foregroundColor(.accentColor)
            Text("A/V Pair focus (\(filterByIDs.count) file\(filterByIDs.count == 1 ? "" : "s"))")
                .font(.system(size: 12, weight: .medium))

            if let score = focusMatchScore {
                let q = CorrelationScorer.MatchQuality.bucket(forScore: score)
                Text("\(q.rawValue) match")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(matchQualityColor(q).opacity(0.18),
                                in: RoundedRectangle(cornerRadius: 4))
                    .foregroundColor(matchQualityColor(q))
                    .help("Score \(score)/14 — Best ≥10, Better 7–9, Good 4–6, Maybe 3")
            }

            Spacer()

            if let rec = records.first(where: { filterByIDs.contains($0.id) }),
               let partner = rec.pairedWith, filterByIDs.contains(partner.id) {
                Button("Combine This Pair…") {
                    let video = rec.streamType == .videoOnly ? rec : partner
                    let audio = rec.streamType == .audioOnly ? rec : partner
                    onCombinePair?(video, audio)
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11))
            }

            Button("Show All") {
                onClearFilter?()
            }
            .buttonStyle(.bordered)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    private func matchQualityColor(_ q: CorrelationScorer.MatchQuality) -> Color {
        switch q {
        case .best:   return .green
        case .better: return .blue
        case .good:   return .orange
        case .maybe:  return .secondary
        }
    }

    // MARK: - Results Table

    private var catalogTable: some View {
        Table(tableData, selection: $selectedIDs, sortOrder: $sortOrder) {
            TableColumn("Filename", value: \.filename) { rec in
                let offline = !VolumeReachability.isReachable(path: rec.fullPath)
                HStack(spacing: 4) {
                    if showPairsOnly && rec.pairedWith != nil {
                        Image(systemName: rec.streamType == .videoOnly ? "film" : "waveform")
                            .font(.system(size: 10))
                            .foregroundColor(rec.streamType == .videoOnly ? .blue : .green)
                    }
                    Text(rec.filename)
                        .font(.system(.body, design: .monospaced))
                        .italic(offline)
                        .foregroundColor(offline ? .secondary
                            : (showPairsOnly && rec.pairedWith != nil
                               ? (rec.streamType == .videoOnly ? .blue : .green)
                               : .primary))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .help(offline ? "\(rec.directory) (offline)" : rec.directory)
            }
            .width(min: 180, ideal: 260)

            TableColumn("Volume", value: \.volumeName) { rec in
                Text(rec.volumeName)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .help(rec.fullPath)
            }
            .width(min: 80, ideal: 120)

            TableColumn("Stream", value: \.streamTypeRaw) { rec in
                let unpaired = rec.streamType.needsCorrelation && rec.pairedWith == nil
                let display = rec.streamType == .ffprobeFailed
                    ? rec.isPlayable
                    : rec.streamTypeRaw
                Text(display)
                    .foregroundColor(unpaired ? .orange : streamTypeColor(rec.streamType))
                    .bold(rec.streamType.needsCorrelation)
                    .help(unpaired
                          ? (rec.streamType == .videoOnly ? "No audio pair found" : "No video pair found")
                          : "V+A = video and audio, V-only/A-only = single stream, or file status if damaged")
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

            TableColumn("Tag") { rec in
                HStack(spacing: 3) {
                    Image(systemName: rec.mediaDisposition.icon)
                        .foregroundColor(rec.mediaDisposition.color)
                    if rec.mediaDisposition != .unreviewed {
                        Text(rec.mediaDisposition.rawValue)
                            .font(.system(size: 11))
                            .foregroundColor(rec.mediaDisposition.color)
                    }
                    if !rec.notes.isEmpty {
                        Image(systemName: "note.text")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                .help(rec.notes.isEmpty
                      ? rec.mediaDisposition.rawValue
                      : "\(rec.mediaDisposition.rawValue) — \(rec.notes)")
            }
            .width(min: 70, ideal: 110)

            TableColumn("Duplicate") { rec in
                DuplicateDispositionCell(record: rec)
                    .help(rec.duplicateDisposition == .none
                          ? "Run Duplicates analysis to check for copies"
                          : "Total copies across catalog. Color: green = Keep (best copy), orange = Review (check manually), red = Extra copy (safe to remove)")
            }
            .width(min: 80, ideal: 95)
        }
        .onChange(of: sortOrder) {
            onSort(sortOrder)
            tableData.sort(using: sortOrder)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            let selectedRecs = ids.compactMap { id in records.first { $0.id == id } }
            if let id = ids.first,
               let rec = records.first(where: { $0.id == id }) {
                Button(VolumeReachability.isReachable(path: rec.fullPath)
                       ? "Reveal in Finder"
                       : "Reveal in Finder (offline)") {
                    if VolumeReachability.isReachable(path: rec.fullPath) {
                        NSWorkspace.shared.selectFile(rec.fullPath, inFileViewerRootedAtPath: "")
                    } else {
                        let alert = NSAlert()
                        alert.messageText = "File Offline"
                        alert.informativeText = "The volume containing this file is not mounted.\n\n\(rec.fullPath)"
                        alert.alertStyle = .informational
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
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

                Divider()

                Menu("Tag") {
                    Button {
                        for r in selectedRecs { r.mediaDisposition = .important }
                        model.saveCatalogDebounced()
                    } label: {
                        Label("Important", systemImage: "star.fill")
                    }
                    Button {
                        for r in selectedRecs { r.mediaDisposition = .recoverable }
                        model.saveCatalogDebounced()
                    } label: {
                        Label("Recoverable", systemImage: "wrench.and.screwdriver.fill")
                    }

                    Divider()

                    Button {
                        for r in selectedRecs { r.mediaDisposition = .suspectedJunk }
                        model.saveCatalogDebounced()
                    } label: {
                        Label("Suspected Junk", systemImage: "exclamationmark.triangle")
                    }
                    Button {
                        for r in selectedRecs { r.mediaDisposition = .confirmedJunk }
                        model.saveCatalogDebounced()
                    } label: {
                        Label("Junk", systemImage: "xmark.circle.fill")
                    }

                    Divider()

                    Button {
                        for r in selectedRecs { r.mediaDisposition = .unreviewed }
                        model.saveCatalogDebounced()
                    } label: {
                        Label("Clear Tag", systemImage: "arrow.counterclockwise")
                    }
                }

                Button("Notes\u{2026}") {
                    notesTarget = rec
                    notesText = rec.notes
                    showNotesSheet = true
                }

                // Show duplicate group matches
                let groupMatches = records.filter {
                    $0.id != rec.id && $0.duplicateGroupID != nil && $0.duplicateGroupID == rec.duplicateGroupID
                }
                if !groupMatches.isEmpty {
                    let onlineMatches = groupMatches.filter {
                        VolumeReachability.isReachable(path: $0.fullPath)
                    }

                    if !onlineMatches.isEmpty {
                        let byVolume = Dictionary(grouping: onlineMatches) {
                            VolumeReachability.volumeName(forPath: $0.fullPath)
                        }
                        Menu("Find Online Copy (\(onlineMatches.count))") {
                            ForEach(byVolume.keys.sorted(), id: \.self) { vol in
                                if let files = byVolume[vol] {
                                    Section(vol) {
                                        ForEach(files) { match in
                                            Button(match.filename) {
                                                NSWorkspace.shared.selectFile(
                                                    match.fullPath,
                                                    inFileViewerRootedAtPath: ""
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Menu("All Matches (\(groupMatches.count))") {
                        ForEach(groupMatches) { dup in
                            let online = VolumeReachability.isReachable(path: dup.fullPath)
                            Button {
                                selectedIDs = [dup.id]
                                onSelect(dup.id)
                            } label: {
                                let vol = VolumeReachability.volumeName(forPath: dup.fullPath)
                                Text("\(dup.filename) — \(vol)\(online ? "" : " (offline)")")
                            }
                        }
                    }
                }

                if rec.streamType.needsCorrelation {
                    Divider()
                    Button("Find A/V Pair") {
                        onFindAVPair?(rec)
                    }
                    .help("Show this file's best matching pair in the catalog, including any online duplicates of either side.")
                }
                if let partner = rec.pairedWith {
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
        .onChange(of: records.count) { tableData = computeFiltered() }
        .onChange(of: searchText) { tableData = computeFiltered() }
        .onChange(of: filterTargetPaths) { tableData = computeFiltered() }
        .onChange(of: showPairsOnly) { tableData = computeFiltered() }
        .onChange(of: filterByIDs) { tableData = computeFiltered() }
        .onChange(of: viewFilters) { tableData = computeFiltered() }
    }

    // MARK: - Preview / Player

    private var previewPlayer: some View {
        Group {
            if selectedRecord != nil {
                HStack(spacing: 0) {
                    // Volume info — lower left
                    if let rec = selectedRecord {
                        VStack(alignment: .leading, spacing: 4) {
                            // Finder-like selection count, above volume name
                            if !selectedIDs.isEmpty {
                                Text("\(selectedIDs.count) selected")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.primary)
                                    .monospacedDigit()
                            }
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
                            || (selectedRecord.map { !VolumeReachability.isReachable(path: $0.fullPath) } ?? false) {
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

struct RenameSheet: View {
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

// MARK: - Notes Sheet

struct NotesSheet: View {
    @Binding var notes: String
    let filename: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notes")
                .font(.headline)
            Text(filename)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
            TextEditor(text: $notes)
                .font(.system(.body))
                .frame(minHeight: 80)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 220)
    }
}

// MARK: - Inspector Panel

struct InspectorPanel: View {
    let record: VideoRecord?
    let duplicateGroupMembers: [VideoRecord]
    let previewImage: NSImage?
    let previewOfflineVolumeName: String?
    var onSelectRecord: ((UUID) -> Void)?

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
                            if rec.streamType == .videoOnly && rec.pairedWith == nil {
                                Text("NO AUDIO")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.orange.opacity(0.12))
                                    )
                            }
                            if rec.streamType == .audioOnly && rec.pairedWith == nil {
                                Text("NO VIDEO")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.orange.opacity(0.12))
                                    )
                            }
                        }
                        // Star rating
                        HStack(spacing: 6) {
                            Text("Rating")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            StarRatingView(rating: Binding(
                                get: { rec.starRating },
                                set: { rec.starRating = $0 }
                            ))
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
                        // Avid identity — tape and clip name at a glance
                        if rec.hasAvidMetadata && (!rec.avidTapeName.isEmpty || !rec.avidClipName.isEmpty) {
                            VStack(alignment: .leading, spacing: 3) {
                                if !rec.avidTapeName.isEmpty {
                                    HStack(spacing: 4) {
                                        Image(systemName: "recordingtape")
                                            .font(.system(size: 10))
                                        Text(rec.avidTapeName)
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                }
                                if !rec.avidClipName.isEmpty {
                                    HStack(spacing: 4) {
                                        Image(systemName: "film.stack")
                                            .font(.system(size: 10))
                                        Text(rec.avidClipName)
                                            .font(.system(size: 11))
                                    }
                                }
                            }
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.cyan.opacity(0.08))
                            )
                            .padding(.top, 4)
                        }
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
                                    Text(
                                        rec.duplicateGroupCount >= 2
                                        ? "\(rec.duplicateDisposition.rawValue) · \(rec.duplicateGroupCount) matches"
                                        : rec.duplicateDisposition.rawValue
                                    )
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

                                Text("Duplicate Group (\(duplicateGroupMembers.count + 1) total)")
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
            .contextMenu {
                Button("Copy All Metadata") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(formatAllMetadata(rec), forType: .string)
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

    // MARK: - Copy Metadata

    private func formatAllMetadata(_ rec: VideoRecord) -> String {
        var lines: [String] = []
        func add(_ label: String, _ value: String) {
            guard !value.isEmpty else { return }
            lines.append("  \(label): \(value)")
        }
        func section(_ title: String) {
            if !lines.isEmpty { lines.append("") }
            lines.append("[\(title)]")
        }

        // Header
        lines.append(rec.filename)
        lines.append("  Stream Type: \(rec.streamTypeRaw)")
        lines.append("  Volume: \(VolumeReachability.volumeName(forPath: rec.fullPath))")
        if rec.starRating > 0 {
            lines.append("  Rating: \(String(repeating: "★", count: rec.starRating))")
        }
        if rec.hasAvidMetadata {
            if !rec.avidTapeName.isEmpty { add("Tape", rec.avidTapeName) }
            if !rec.avidClipName.isEmpty { add("Clip", rec.avidClipName) }
        }

        // General
        section("General")
        add("Size", rec.size)
        add("Duration", rec.duration)
        add("Container", rec.container)
        add("Extension", rec.ext)

        // Video
        section("Video")
        add("Resolution", rec.resolution)
        add("Codec", rec.videoCodec)
        add("Frame Rate", rec.frameRate)
        add("Bitrate", rec.videoBitrate)
        add("Total Bitrate", rec.totalBitrate)
        add("Color Space", rec.colorSpace)
        add("Bit Depth", rec.bitDepth)
        add("Scan Type", rec.scanType)

        // Audio
        section("Audio")
        add("Codec", rec.audioCodec)
        add("Channels", rec.audioChannels)
        add("Sample Rate", rec.audioSampleRate)

        // Timestamps
        section("Timestamps")
        add("Created", rec.dateCreated)
        add("Modified", rec.dateModified)
        add("Timecode", rec.timecode)
        add("Tape Name", rec.tapeName)

        // Correlation
        if rec.pairedWith != nil || rec.pairConfidence != nil {
            section("Correlation")
            if let paired = rec.pairedWith {
                add("Paired With", paired.filename)
                add("Pair Volume", VolumeReachability.volumeName(forPath: paired.fullPath))
                add("Pair Path", paired.fullPath)
            }
            if let conf = rec.pairConfidence {
                add("Confidence", conf.rawValue)
            }
        }

        // Duplicates
        if rec.duplicateDisposition != .none || !rec.duplicateBestMatchFilename.isEmpty {
            section("Duplicates")
            if rec.duplicateDisposition != .none {
                let status = rec.duplicateGroupCount >= 2
                    ? "\(rec.duplicateDisposition.rawValue) · \(rec.duplicateGroupCount) matches"
                    : rec.duplicateDisposition.rawValue
                add("Status", status)
            }
            add("Reasons", rec.duplicateReasons)
            if let conf = rec.duplicateConfidence {
                add("Confidence", conf.rawValue)
            }
            if !duplicateGroupMembers.isEmpty {
                lines.append("")
                lines.append("  Duplicate Group (\(duplicateGroupMembers.count + 1) total):")
                let thisVol = VolumeReachability.volumeName(forPath: rec.fullPath)
                lines.append("    ★ \(rec.filename)  [\(thisVol)]  \(rec.duplicateDisposition.rawValue)")
                for member in duplicateGroupMembers {
                    let vol = VolumeReachability.volumeName(forPath: member.fullPath)
                    let online = VolumeReachability.isReachable(path: member.fullPath)
                    lines.append("    · \(member.filename)  [\(vol)]\(online ? "" : " (offline)")  \(member.duplicateDisposition.rawValue)")
                }
            }
        }

        // Avid Project
        if rec.hasAvidMetadata {
            section("Avid Project")
            add("Clip Name", rec.avidClipName)
            add("Mob Type", rec.avidMobType)
            add("Bin File", rec.avidBinFile)
            add("Tape", rec.avidTapeName)
            add("Tracks", rec.avidTracks)
            if rec.avidEditRate > 0 { add("Edit Rate", String(format: "%.2f fps", rec.avidEditRate)) }
            add("Mob ID", rec.avidMobID)
            add("Material UUID", rec.avidMaterialUUID)
            add("Original Path", rec.avidMediaPath)
        }

        // Notes
        if !rec.notes.isEmpty {
            section("Notes")
            lines.append("  \(rec.notes)")
        }

        // Location
        section("Location")
        add("Path", rec.fullPath)
        add("Directory", rec.directory)
        add("MD5 (partial)", rec.partialMD5)

        return lines.joined(separator: "\n")
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

struct DuplicateDispositionCell: View {
    let record: VideoRecord

    var body: some View {
        HStack(spacing: 4) {
            if let conf = record.duplicateConfidence {
                Circle()
                    .fill(conf.textColor)
                    .frame(width: 8, height: 8)
            }
            Text(duplicateDisplayLabel(for: record))
                .foregroundColor(record.duplicateDisposition.textColor)
        }
    }
}

func duplicateDisplayLabel(for record: VideoRecord) -> String {
    if record.duplicateDisposition == .none { return "—" }
    let n = record.duplicateGroupCount
    if n >= 2 { return "\(n) matches" }
    return record.duplicateDisposition.rawValue
}

// MARK: - Discover Volumes Sheet

struct DiscoverVolumesSheet: View {
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

// MARK: - Scan Options Menu

/// Toolbar menu for toggling what the walker descends into and two perf
/// shortcuts. All toggles are applied at scan start (not mid-scan), so the
/// next "Scan All" reflects the new policy. Defaults = aggressive skip
/// (only descend where family media plausibly lives).
struct ScanOptionsMenu: View {
    @ObservedObject var model: VideoScanModel

    /// Binding wrapper that saves to UserDefaults on every toggle, so the
    /// user's preference survives relaunch without an explicit "Save" step.
    private func toggle(_ keyPath: WritableKeyPath<ScanOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.scanOptions[keyPath: keyPath] },
            set: { newVal in
                model.scanOptions[keyPath: keyPath] = newVal
                model.scanOptions.save()
            }
        )
    }

    var body: some View {
        Menu {
            Toggle("Skip System Files", isOn: toggle(\.skipSystemFiles))
            Toggle("Skip Media Bundles", isOn: toggle(\.skipMediaBundles))
            Toggle("Skip Small Files", isOn: toggle(\.skipSmallFiles))
            Toggle("Skip Checksums", isOn: toggle(\.skipChecksums))

            Divider()

            Button("Fast Defaults") {
                model.scanOptions = .fastDefaults
                model.scanOptions.save()
            }
            .disabled(model.scanOptions == .fastDefaults)

            Button("Scan Everything (Slower)") {
                model.scanOptions = .thorough
                model.scanOptions.save()
            }
            .disabled(model.scanOptions == .thorough)
        } label: {
            HStack(spacing: 4) {
                Label("Scan Options", systemImage: "slider.horizontal.3")
                // Accent-colored dot when the user has deviated from the
                // fast-path defaults — visible at a glance.
                if model.scanOptions.isCustomized {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(model.scanOptions.isCustomized
              ? "Non-default scan policy (applies on next scan)"
              : "What to skip during scan (applies on next scan)")
    }
}

// MARK: - Star Rating View

struct StarRatingView: View {
    @Binding var rating: Int
    let maxStars: Int = 3

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...maxStars, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.system(size: 14))
                    .foregroundColor(star <= rating ? .yellow : .secondary.opacity(0.4))
                    .onTapGesture {
                        rating = (rating == star) ? 0 : star
                    }
            }
        }
    }
}
