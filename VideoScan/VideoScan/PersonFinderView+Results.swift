// PersonFinderView+Results.swift
// The Results section — the results Table and its sort/selection wiring,
// the per-result detail bar, the right-click context menu, catalog
// navigation, QuickTime playback, and the stream inspector popover —
// extracted verbatim from PersonFinderView's body in
// PersonFinderView.swift (refactor 2026-06-24). Members shared with the
// other split files (`infoRow`, `pfViewLog`) are internal in the main
// file; `private` here is file-private to THIS file.

import SwiftUI
import AppKit
import os.log

extension PersonFinderView {

    // MARK: Results table

    private func matchColor(_ dist: Float) -> Color {
        if dist < 0.5 { return .green }
        if dist < 0.65 { return .yellow }
        return .orange
    }

    private var resultTableView: some View {
        resultTableCore
            .onChange(of: resultSortOrder) {
                resultTableData.sort(using: resultSortOrder)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                resultContextMenu(ids: ids)
            } primaryAction: { ids in
                guard let id = ids.first,
                      let rec = resultTableData.first(where: { $0.id == id }) else { return }
                playInQuickTime(rec)
            }
            .frame(minHeight: 120)
            .popover(isPresented: $inspectorShown, arrowEdge: .trailing) {
                if let rec = selectedResult {
                    inspectorPopover(rec)
                }
            }
            .onChange(of: selectedResultIDs) {
                guard inspectorShown, let rec = selectedResult else { return }
                loadStreamInfo(for: rec)
            }
            .onKeyPress(phases: .down) { press in
                guard press.key == KeyEquivalent("i"),
                      press.modifiers == .command,
                      let rec = selectedResult else { return .ignored }
                openInspector(for: rec)
                return .handled
            }
    }

    private var resultTableCore: some View {
        Table(resultTableData, selection: $selectedResultIDs, sortOrder: $resultSortOrder) {
            TableColumn("Video File", value: \.videoFilename) { r in
                Text(r.videoFilename)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .help(r.videoPath)
            }
            .width(min: 200, ideal: 300)

            TableColumn("Duration", value: \.videoDuration) { r in
                Text(pfFormatDuration(r.videoDuration))
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 70, ideal: 80)

            TableColumn("Presence", value: \.presenceSecs) { r in
                Text(pfFormatDuration(r.presenceSecs))
                    .font(.system(.body, design: .monospaced).weight(.medium))
                    .foregroundColor(.green)
            }
            .width(min: 70, ideal: 80)

            TableColumn("Clips", value: \.segmentCount) { r in
                Text("\(r.segmentCount)")
                    .font(.body)
            }
            .width(min: 50, ideal: 60)

            TableColumn("Best Match", value: \.bestDistance) { r in
                Text(String(format: "%.3f", r.bestDistance))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(matchColor(r.bestDistance))
            }
            .width(min: 80, ideal: 90)
        }
    }

    private var selectedResult: ClipResult? {
        guard let id = selectedResultIDs.first else { return nil }
        return resultTableData.first { $0.id == id }
    }

    private func recomputeResults() {
        let raw = selectedJob?.results ?? model.jobs.flatMap { $0.results }
        resultTableData = raw.sorted(using: resultSortOrder)
    }

    var resultsTable: some View {
        Group {
            if resultTableData.isEmpty {
                HStack(spacing: 6) {
                    let anyDone = model.jobs.contains { $0.status == .done || $0.status == .cancelled }
                    let anyActive = model.jobs.contains { $0.status.isActive }
                    Image(systemName: "tray")
                        .foregroundColor(.secondary)
                    Text(anyDone && !anyActive
                         ? "No matches found"
                         : anyActive
                         ? "Results will appear as matches are found"
                         : "Results will appear here when matches are found")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            } else {
                VStack(spacing: 0) {
                    resultTableView
                    if let rec = selectedResult {
                        Divider()
                        resultDetailBar(rec)
                    }
                }
            }
        }
        .onAppear { recomputeResults() }
        .onChange(of: selectedJobID) { recomputeResults() }
        .onChange(of: model.jobs.flatMap(\.results).count) { recomputeResults() }
    }

    private func resultDetailBar(_ rec: ClipResult) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.videoFilename)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                Text(rec.videoPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            HStack(spacing: 14) {
                VStack(spacing: 2) {
                    Text("Duration")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text(pfFormatDuration(rec.videoDuration))
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                }
                VStack(spacing: 2) {
                    Text("Presence")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text(pfFormatDuration(rec.presenceSecs))
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundColor(.green)
                }
                VStack(spacing: 2) {
                    Text("Clips")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text("\(rec.segmentCount)")
                        .font(.system(size: 16, weight: .medium))
                }
                VStack(spacing: 2) {
                    Text("Best Match")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Text(String(format: "%.3f", rec.bestDistance))
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundColor(rec.bestDistance < 0.5 ? .green : rec.bestDistance < 0.65 ? .yellow : .orange)
                }
            }

            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.selectFile(rec.videoPath, inFileViewerRootedAtPath: "")
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.blue)

                Button {
                    playInQuickTime(rec)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(.blue)

                Button {
                    openInspector(for: rec)
                } label: {
                    Label("Inspect", systemImage: "info.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.blue)
                .keyboardShortcut("i", modifiers: .command)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    /// Launches QuickTime Player for the given result. Used by the Play
    /// button, the context menu, and the table-row double-click action.
    private func playInQuickTime(_ rec: ClipResult) {
        guard let qtURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.QuickTimePlayerX"
        ) else {
            pfViewLog.error("QuickTime Player not found on this machine")
            return
        }
        pfViewLog.info("Open in QuickTime: \(rec.videoPath, privacy: .public)")
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: rec.videoPath)],
            withApplicationAt: qtURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    // MARK: Result Context Menu

    @ViewBuilder
    private func resultContextMenu(ids: Set<UUID>) -> some View {
        if let id = ids.first,
           let rec = resultTableData.first(where: { $0.id == id }) {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(rec.videoPath, inFileViewerRootedAtPath: "")
            }
            Button("Open in QuickTime Player") {
                playInQuickTime(rec)
            }
            if !rec.clipFiles.isEmpty {
                Button("Reveal Clips in Finder") {
                    revealClips(for: rec)
                }
            }
            Divider()
            Button("Inspect\u{2026}") {
                openInspector(for: rec)
            }
            Button("Show in Catalog") {
                showInCatalog(path: rec.videoPath)
            }
            .disabled(!isInCatalog(path: rec.videoPath))
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rec.videoPath, forType: .string)
            }
        }
    }

    // MARK: Catalog Navigation

    private func isInCatalog(path: String) -> Bool {
        catalogModel.records.contains { $0.fullPath == path }
    }

    private func showInCatalog(path: String) {
        guard let rec = catalogModel.records.first(where: { $0.fullPath == path }) else { return }
        catalogModel.pendingCatalogSelection = rec.id
        selectedTab = 1
    }

    // MARK: Inspector

    private func openInspector(for rec: ClipResult) {
        selectedResultIDs = [rec.id]
        inspectorStreamInfo = nil
        inspectorShown = true
        loadStreamInfo(for: rec)
    }

    private func loadStreamInfo(for rec: ClipResult) {
        inspectorStreamInfo = nil
        inspectorLoading = true
        Task {
            let info = await StreamInspectInfo.probe(path: rec.videoPath)
            inspectorStreamInfo = info
            inspectorLoading = false
        }
    }

    func inspectorPopover(_ rec: ClipResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(rec.videoFilename).font(.headline)
                Spacer()
                Text("\u{2191}\u{2193} to browse")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Divider()
            infoRow("Path", rec.videoPath)
            infoRow("Duration", pfFormatDuration(rec.videoDuration))
            infoRow("Presence", pfFormatDuration(rec.presenceSecs))
            infoRow("Segments", "\(rec.segmentCount)")
            infoRow("Best Match", String(format: "%.3f", rec.bestDistance))
            if !rec.outputDir.isEmpty {
                infoRow("Output Dir", rec.outputDir)
            }

            if !rec.clipFiles.isEmpty {
                Divider()
                Text("Clip Files").font(.subheadline.weight(.medium))
                ForEach(rec.clipFiles, id: \.self) { clip in
                    Text(clip)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Divider()

            if inspectorLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Probing streams\u{2026}")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            } else if let info = inspectorStreamInfo {
                infoRow("Format", info.formatName)
                infoRow("File Size", info.fileSize)
                infoRow("Bitrate", info.bitrate)

                if info.streams.isEmpty {
                    Text("No streams detected")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                } else {
                    ForEach(Array(info.streams.enumerated()), id: \.offset) { _, stream in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: stream.icon)
                                .foregroundColor(stream.color)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stream.summary)
                                    .font(.system(size: 11, design: .monospaced))
                                if !stream.detail.isEmpty {
                                    Text(stream.detail)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                if info.hasVideo && !info.hasAudio {
                    Label("No audio track", systemImage: "speaker.slash.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.orange)
                }

                if let diagnosis = info.diagnosis {
                    Label(diagnosis, systemImage: info.diagnosisIsWarning
                          ? "exclamationmark.triangle" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(info.diagnosisIsWarning ? .yellow : .red)
                }
            }
        }
        .padding()
        .frame(minWidth: 360, maxWidth: 520)
    }

    func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}
