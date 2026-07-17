import SwiftUI

// MARK: - Balance Audio sheet (analyze-then-confirm)
//
// "Balance Audio…" — GH #116. Presented via `.sheet(item:)` from the
// catalog row context menu (NEVER chained isPresented sheets —
// documented antipattern). Mirrors Trim/Clean Up's look-before-leap
// shape, with the ANALYSIS as the look: the sheet immediately runs the
// audio channel analyzer (seconds — audio decode only), shows the
// verdict in plain family language with per-channel levels, and only
// offers the Balance button when a fix actually applies. Non-actionable
// classes (true stereo, already balanced, silent, surround) show the
// explanation with no button — the user learns why nothing needs doing.
//
// Text sizes are deliberately generous (.title2/.body, nothing smaller
// than .callout) — large readable text is an accessibility need here,
// not polish.

/// A pending sheet presentation. Fresh ID per menu click (same shape as
/// CleanupRequest). The destination is computed ONCE here and handed to
/// BOTH the sheet (display) and the job (planned output) — the m3
/// convention; the job's publish step re-uniquifies as the last word.
struct BalanceAudioRequest: Identifiable {
    let id = UUID()
    let record: VideoRecord
    /// Planned `<stem>_balanced.<ext>` beside the original, uniquified
    /// against files existing right now.
    let destinationURL: URL

    @MainActor
    init(record: VideoRecord) {
        self.record = record
        self.destinationURL = BalanceAudioFix.balancedOutputURL(
            forSourcePath: record.fullPath)
    }
}

struct BalanceAudioSheet: View {
    @EnvironmentObject private var fileOpsCenter: MediaFileOperationsCenter
    // Forwarded to MediaFileOperationsCenter when the job starts (same
    // intentional forwarding as CleanupSheet/TranscodeSheet).
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject private var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let request: BalanceAudioRequest

    /// The analyze-first phase. (≈ a C++ tagged union / std::variant.)
    private enum Phase {
        case analyzing
        case analyzed(AudioBalanceAnalysis)
        case failed(String)
    }
    @State private var phase: Phase = .analyzing

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Balance Audio")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("balanceSheet.title")

            Text(request.record.filename)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

            switch phase {
            case .analyzing:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Listening to the audio channels…")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 20)
                .accessibilityIdentifier("balanceSheet.analyzing")

            case .failed(let message):
                Label {
                    Text(message)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
                .accessibilityIdentifier("balanceSheet.error")

            case .analyzed(let analysis):
                analysisView(analysis)
            }

            HStack {
                Spacer()
                Button(actionable == nil ? "Close" : "Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                if let analysis = actionable {
                    Button("Balance") { startBalance(analysis) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return)
                        .accessibilityIdentifier("balanceSheet.balanceButton")
                }
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 560)
        // Runs once per presentation; the probe is @concurrent so the
        // decode never touches the main thread.
        .task { await runAnalysis() }
    }

    /// The analysis, but only when a fix applies (drives the button).
    private var actionable: AudioBalanceAnalysis? {
        if case .analyzed(let analysis) = phase,
           BalanceAudioFix.refusalReason(for: analysis.classification) == nil {
            return analysis
        }
        return nil
    }

    // MARK: Analysis display

    @ViewBuilder
    private func analysisView(_ analysis: AudioBalanceAnalysis) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(analysis.classification.familyDescription)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("balanceSheet.classification")
                channelLevelRows(analysis.measurements)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }

        if actionable != nil {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(fixDescription(analysis.classification))
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "speaker.wave.2.circle.fill")
                            .foregroundColor(.accentColor)
                    }
                    Label {
                        Text("The picture is copied exactly — only the sound is touched.")
                            .font(.body)
                    } icon: {
                        Image(systemName: "film")
                            .foregroundColor(.accentColor)
                    }
                    Label {
                        Text("Your original file is never changed.")
                            .font(.body.weight(.medium))
                    } icon: {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.green)
                    }
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("The balanced copy will be saved next to it as:")
                                .font(.body)
                            Text(request.destinationURL.lastPathComponent)
                                .font(.body.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } icon: {
                        Image(systemName: "doc.badge.plus")
                            .foregroundColor(.accentColor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
        }
    }

    /// One row per measured channel: "Left — has sound (−18 dB)" /
    /// "Right — silent". Channels beyond 2 are numbered.
    @ViewBuilder
    private func channelLevelRows(_ m: AudioBalanceMeasurements) -> some View {
        ForEach(Array(m.channels.enumerated()), id: \.offset) { index, channel in
            let hasSound = AudioBalanceClassifier.carriesProgram(channel)
            HStack(spacing: 8) {
                Image(systemName: hasSound
                      ? "speaker.wave.2.fill"
                      : "speaker.slash.fill")
                    .foregroundColor(hasSound ? .accentColor : .secondary)
                Text("\(channelName(index, of: m.channels.count)) — \(levelText(channel))")
                    .font(.callout)
                    .foregroundColor(hasSound ? .primary : .secondary)
            }
        }
    }

    private func channelName(_ index: Int, of count: Int) -> String {
        guard count == 2 else {
            return count == 1 ? "Sound" : "Channel \(index + 1)"
        }
        return index == 0 ? "Left" : "Right"
    }

    private func levelText(_ channel: AudioChannelLevels) -> String {
        guard channel.rmsDBFS.isFinite else { return "silent" }
        guard AudioBalanceClassifier.carriesProgram(channel) else {
            return "effectively silent"
        }
        return String(format: "has sound (%.0f dB)", channel.rmsDBFS)
    }

    private func fixDescription(_ c: AudioChannelClass) -> String {
        switch c {
        case .leftOnly:
            return "The left channel's sound will be copied to both speakers."
        case .rightOnly:
            return "The right channel's sound will be copied to both speakers."
        case .mono:
            return "The mono sound will be spread evenly to both speakers."
        default:
            return c.familyDescription
        }
    }

    // MARK: Actions

    private func runAnalysis() async {
        let path = request.record.fullPath
        do {
            let analysis = try await AudioBalanceProbe.analyze(path: path)
            phase = .analyzed(analysis)
        } catch AudioBalanceProbeError.noAudioStream {
            phase = .failed("This file has no audio stream to balance.")
        } catch AudioBalanceProbeError.toolUnavailable(let detail) {
            phase = .failed(detail)
        } catch AudioBalanceProbeError.probeFailed(let detail) {
            phase = .failed("Could not analyze the audio — \(detail)")
        } catch {
            phase = .failed("Could not analyze the audio — \(error.localizedDescription)")
        }
    }

    private func startBalance(_ analysis: AudioBalanceAnalysis) {
        fileOpsCenter.startBalanceAudio(record: request.record,
                                        analysis: analysis,
                                        model: model,
                                        plannedOutput: request.destinationURL)
        dismiss()
        // Same handoff CleanupSheet uses: open the operations window
        // (progress + Cancel live there) after the dismissal starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            openWindow(id: "combine")
        }
    }
}
