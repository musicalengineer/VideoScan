// ScanJobRow+Expanded.swift
// The expanded detail area of a job row — status summary line, progress ring,
// the Create Composite Video panel, full-label action buttons, and the
// compiled-outputs list — extracted verbatim from ScanJobRow's body in
// ScanJobRow.swift (refactor 2026-06-25). A cross-file `extension` can't see
// `private` members, so the ScanJobRow computed properties this code shares
// (isIdle/isActive/isScanning/personName/volName/engineName/isJobDone) were
// widened to internal in the main file.
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state allowed, methods share the same `self`; `private` here means
// file-private to THIS file.)

import SwiftUI
import AppKit

extension ScanJobRow {

    // MARK: - Expanded detail

    var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status summary line for non-idle jobs
            if !isIdle {
                HStack(spacing: 10) {
                    if isScanning {
                        SpinningRing(color: statusColor, size: 22)
                    }

                    if isJobDone {
                        expandedSummarySentence
                    } else {
                        let prefix: String = {
                            switch job.status {
                            case .cancelled: return "Stopped:"
                            case .failed: return "Failed:"
                            case .scanning: return "Searching for"
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
            }

            // Stats + full action buttons
            HStack(spacing: 10) {
                if job.videosTotal > 0 {
                    Label("\(job.videosWithHits) matches", systemImage: "person.fill.checkmark")
                        .font(.body.weight(.medium))
                        .foregroundColor(.green)
                    Text("\(job.status.isCompleted ? job.videosTotal : job.videosScanned) / \(job.videosTotal) videos")
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

            // Progress ring — snap to 100% when done to avoid stale partial display
            if job.videosTotal > 0 {
                ScanRingChart(
                    total: job.videosTotal,
                    scanned: job.status.isCompleted ? job.videosTotal : job.videosScanned,
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

            // Create Composite Video panel — appears when scan is done with results
            if job.status.isDone && !job.results.isEmpty {
                compilationPanel
            }

            // Compiled outputs
            if !job.compiledVideoPaths.isEmpty {
                compiledOutputsView
            }
        }
    }

    // MARK: - Create Composite Video panel

    var compilationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "film.stack.fill")
                    .foregroundColor(.accentColor)
                Text("Create Composite Video")
                    .font(.system(.callout, weight: .semibold))
            }

            // Output folder — always visible
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundColor(.secondary)
                if job.compilationStatus.isActive {
                    Text(model.settings.outputDir.isEmpty
                         ? "~/Desktop/\(pfSanitize(job.assignedProfile?.name ?? "clips"))_clips"
                         : model.settings.outputDir)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    TextField(
                        "Default: ~/Desktop/\(pfSanitize(job.assignedProfile?.name ?? "clips"))_clips",
                        text: model.settingsBinding.outputDir
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                }

                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Select"
                    panel.begin { response in
                        if response == .OK, let url = panel.url {
                            model.settings.outputDir = url.path
                            model.settings.save()
                        }
                    }
                }
                .controlSize(.small)
                .disabled(job.compilationStatus.isActive)

                if !model.settings.outputDir.isEmpty {
                    Button("Reveal") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: model.settings.outputDir))
                    }
                    .controlSize(.small)
                }
            }

            if job.compilationStatus.isActive {
                VStack(alignment: .leading, spacing: 6) {
                    if job.compilationStatus == .extracting {
                        ProgressView(value: job.compilationProgress, total: 1.0)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }

                    HStack(spacing: 8) {
                        Text(job.compilationStatus.label)
                            .font(.headline)
                            .foregroundColor(.orange)
                        Text(job.compilationPhase)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if job.compilationStatus == .extracting, job.compilationClipsTotal > 0 {
                            Text("\(job.compilationClipsDone)/\(job.compilationClipsTotal) clips")
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }

                    Button(role: .destructive) {
                        model.cancelCompilation(job: job)
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else if job.compilationStatus == .done {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(job.compilationPhase)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Generate Again") {
                        model.startCompilation(job: job)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                // Mode + Generate
                HStack(spacing: 12) {
                    Picker("Output", selection: Binding(
                        get: { model.compilationSettings.mode },
                        set: { model.compilationSettings.mode = $0 }
                    )) {
                        ForEach(CompilationMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)

                    Spacer()

                    Button {
                        model.startCompilation(job: job)
                    } label: {
                        Label("Generate", systemImage: "film.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(job.recognitionResults.isEmpty)
                }

                Text("\(job.clipsFound) segment(s) from \(job.results.count) video(s) ready to compile")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.06))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Expanded action buttons (full labels)

    @ViewBuilder
    var expandedActionButtons: some View {
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

    var compiledOutputsView: some View {
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
}
