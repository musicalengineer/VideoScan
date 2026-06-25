// ScanJobRow.swift
// Per-job row in the Person Finder jobs list — inline pickers, progress ring,
// engine settings popover, compiled output links.
//
// The row's larger subviews are split into cohesive extension files
// (refactor 2026-06-25):
//   • ScanJobRow+Summary.swift  — search-complete summary sentences
//   • ScanJobRow+Pickers.swift  — inline person/volume/engine pickers + popover
//   • ScanJobRow+Expanded.swift — expanded detail, compilation panel, outputs
// Stored state and the always-visible collapsed row live here.

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

    // `internal` (no keyword): read by the inline pickers in
    // ScanJobRow+Pickers.swift.
    @State var showSettingsPopover = false
    // `internal` (no keyword): set by the action buttons in
    // ScanJobRow+Expanded.swift.
    @State var startAlert: String?

    // The following derived flags/labels are referenced from the split
    // extension files (Summary/Expanded), so they're internal rather than
    // file-private.
    var isIdle: Bool { job.status.isIdle }
    var isActive: Bool { job.status.isActive }
    var isScanning: Bool { job.status == .scanning }

    var personName: String { job.assignedProfile?.name ?? "—" }
    var volName: String { (job.searchPath as NSString).lastPathComponent }
    /// Prose form for inline use ("using algorithm: ArcFace") — friendly
    /// mixed case, no parenthetical descriptor. See displayName on
    /// RecognitionEngine.
    var engineName: String { job.effectiveEngine.displayName }

    /// True only when the job's volume path is unreachable (e.g. external
    /// drive unmounted) AND we're rendering a row that already had its
    /// search complete. Live scans never see this — they'd be erroring
    /// out a different way. Cached at the VolumeReachability layer (60s
    /// TTL) so per-row redraws aren't expensive.
    var isVolumeOffline: Bool {
        guard job.status.isTerminal, !job.searchPath.isEmpty else { return false }
        return !VolumeReachability.isReachable(path: job.searchPath)
    }

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
                inlinePersonPicker
                inlineVolumePicker
                inlineEnginePicker
            } else if !isExpanded {
                if isJobDone {
                    summarySentence
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
            }

            Spacer()

            // Compact stats on collapsed row — suppressed for .done
            // (the summary sentence already includes the counts).
            if job.videosTotal > 0 && !isJobDone {
                Text("\(job.videosWithHits)")
                    .font(.system(.body, design: .monospaced).weight(.bold))
                    .foregroundColor(.green)
                Text("/")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Text("\(job.status.isCompleted ? job.videosTotal : job.videosScanned)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if job.elapsedSecs > 0 && !isJobDone {
                Text(formatElapsed(job.elapsedSecs))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if !isJobDone {
                statusBadge
            }

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

    // MARK: - Search-complete summary gate
    //
    // The summary sentences themselves live in ScanJobRow+Summary.swift.
    // ScanJobStatus.isDone also returns true for .cancelled, which is NOT
    // what we want for the sentence — `isJobDone` below is the precise gate,
    // and it's referenced from both this file and the summary/expanded
    // extensions, so it's internal.

    /// True only for the truly-completed `.done` state.
    var isJobDone: Bool {
        if case .done = job.status { return true }
        return false
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

    var statusColor: Color {
        switch job.status {
        case .idle:       return .secondary
        case .loading:    return .yellow
        case .scanning:   return .blue
        case .paused:     return .yellow
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
