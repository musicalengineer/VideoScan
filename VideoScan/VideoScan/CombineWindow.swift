import SwiftUI

/// Floating window showing live progress for all Combine & Render jobs.
struct CombineWindow: View {
    @EnvironmentObject var model: VideoScanModel
    @EnvironmentObject var dashboard: DashboardState
    @State private var selectedJob: UUID?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if dashboard.combineJobs.isEmpty && !model.isCombining {
                emptyState
            } else {
                jobList
            }
            Divider()
            footerBar
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 340, idealHeight: 520)
        .onAppear {
            DispatchQueue.main.async {
                for window in NSApp.windows where window.title.contains("Combine") {
                    window.level = .floating
                    window.isMovableByWindowBackground = true
                }
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Image(systemName: "film.stack")
                .foregroundColor(.blue)
            Text("Combine & Render")
                .font(.headline)

            Spacer()

            if model.isCombining {
                overallProgress
            } else if dashboard.combineTotal > 0 {
                Text("Complete")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.green)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var overallProgress: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("\(dashboard.combineCompleted)/\(dashboard.combineTotal)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
            if let start = dashboard.combineStartTime {
                Text(elapsedString(since: start))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.4))
            Text("No combine jobs running")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Start a combine from Catalog → Correlate → Combine")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Job List

    private var jobList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(dashboard.combineJobs) { job in
                    jobRow(job)
                        .onTapGesture {
                            selectedJob = (selectedJob == job.id) ? nil : job.id
                        }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func jobRow(_ job: CombineJobStatus) -> some View {
        let isSelected = selectedJob == job.id

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                phaseIcon(job.phase)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: "film")
                            .font(.system(size: 12))
                            .foregroundColor(.blue)
                        Text(job.videoFilename)
                            .font(.system(size: 13, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("+")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Image(systemName: "waveform")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                        Text(job.audioFilename)
                            .font(.system(size: 13, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    HStack(spacing: 10) {
                        Text(job.technique.rawValue)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Text(Formatting.humanSize(job.estimatedBytes))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)

                        if job.isPaused {
                            Text("PAUSED")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.orange)
                        }
                    }
                }

                Spacer()

                // Progress / status
                VStack(alignment: .trailing, spacing: 3) {
                    if isActivePhase(job.phase) {
                        if job.progressFraction > 0 {
                            Text("\(Int(job.progressFraction * 100))%")
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundColor(.blue)
                        } else {
                            phaseLabel(job.phase)
                        }
                    } else {
                        phaseLabel(job.phase)
                    }
                    if let elapsed = job.elapsed {
                        Text(formatDuration(elapsed))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Progress bar for active jobs
            if isActivePhase(job.phase) {
                ProgressView(value: job.phase == .verifying ? 1.0 : job.progressFraction)
                    .tint(job.phase == .verifying ? .orange
                          : (job.isPaused ? .orange
                             : (job.phase == .buffering ? .orange : .blue)))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            jobWarningAndActions(job, isSelected: isSelected)
        }
        .background(rowBackground(job, selected: isSelected))
    }

    @ViewBuilder
    private func jobWarningAndActions(_ job: CombineJobStatus, isSelected: Bool) -> some View {
        if let warning = job.warningMessage {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 12))
                Text(warning)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.orange)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
        }

        if isSelected {
            HStack(spacing: 8) {
                Spacer()
                if job.phase == .done {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(job.outputPath, inFileViewerRootedAtPath: "")
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.bordered)
                }
                if job.phase == .muxing || job.phase == .buffering || job.phase == .queued {
                    Button(job.isPaused ? "Resume" : "Pause") {
                        model.toggleJobPause(job.pairIndex)
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func phaseIcon(_ phase: CombineJobStatus.CombinePhase) -> some View {
        switch phase {
        case .queued:
            Image(systemName: "clock")
                .foregroundColor(.secondary)
                .font(.system(size: 16))
        case .buffering:
            ProgressView()
                .controlSize(.regular)
        case .muxing:
            ProgressView()
                .controlSize(.regular)
        case .verifying:
            Image(systemName: "checkmark.shield")
                .foregroundColor(.orange)
                .font(.system(size: 16))
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 17))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
                .font(.system(size: 17))
        case .skipped:
            Image(systemName: "arrow.right.circle")
                .foregroundColor(.secondary)
                .font(.system(size: 17))
        }
    }

    private func phaseLabel(_ phase: CombineJobStatus.CombinePhase) -> some View {
        Text(phase.rawValue)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(phaseColor(phase))
    }

    private func phaseColor(_ phase: CombineJobStatus.CombinePhase) -> Color {
        switch phase {
        case .queued: .secondary
        case .buffering: .orange
        case .muxing: .blue
        case .verifying: .orange
        case .done: .green
        case .failed: .red
        case .skipped: .secondary
        }
    }

    private func isActivePhase(_ phase: CombineJobStatus.CombinePhase) -> Bool {
        phase == .buffering || phase == .muxing || phase == .verifying
    }

    private func rowBackground(_ job: CombineJobStatus, selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(selected
                  ? Color.accentColor.opacity(0.1)
                  : (isActivePhase(job.phase)
                     ? Color.accentColor.opacity(0.04)
                     : Color.clear))
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            if dashboard.combineSucceeded > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 13))
                    Text("\(dashboard.combineSucceeded) verified")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.green)
                }
            }
            if dashboard.combineSkipped > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.right.circle")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                    Text("\(dashboard.combineSkipped) already combined")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            if dashboard.combineFailed > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 13))
                    Text("\(dashboard.combineFailed) failed")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.red)
                }
            }

            Spacer()

            if model.isCombining {
                Button(model.isCombinePaused ? "Resume All" : "Pause All") {
                    if model.isCombinePaused {
                        model.resumeCombine()
                    } else {
                        model.pauseCombine()
                    }
                }
                Button("Stop All") { model.stopCombine() }
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - Helpers

    private func elapsedString(since date: Date) -> String {
        formatDuration(Date().timeIntervalSince(date))
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let s = Int(interval)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}
