import SwiftUI

// MARK: - Verify Audio sheet (diagnose-then-offer)
//
// "Verify Audio…" — GH #128. Presented via `.sheet(item:)` from the
// catalog row context menu (NEVER chained isPresented sheets —
// documented antipattern). Mirrors BalanceAudioSheet's analyze-first
// shape, but generalized: the diagnosis produces a FINDINGS LIST, and
// each finding carries at most ONE action button where a repair exists
// (Balance Audio for imbalance, Rebuild Audio Track for codec trouble).
// Healthy files get the "All is well" verdict with the full tech
// readout. No jargon dead-ends — every finding explains itself in
// family language and says what (if anything) can be done.
//
// The diagnosis verdict PERSISTS: on completion the record's
// audioVerifyStatus / audioVerifyNote / audioVerifyDate are written
// (damaged rows render red in the catalog so Rick can batch-find and
// delete them later).
//
// Text sizes are deliberately generous (.title2/.body, nothing smaller
// than .callout) — large readable text is an accessibility need here,
// not polish.

/// A pending sheet presentation. Fresh ID per menu click (same shape as
/// BalanceAudioRequest).
struct VerifyAudioRequest: Identifiable {
    let id = UUID()
    let record: VideoRecord
}

struct VerifyAudioSheet: View {
    @EnvironmentObject private var fileOpsCenter: MediaFileOperationsCenter
    @EnvironmentObject private var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let request: VerifyAudioRequest

    /// The diagnose-first phase. (≈ a C++ tagged union / std::variant.)
    private enum Phase {
        case analyzing
        case diagnosed(AudioVerifyDiagnosis)
        case failed(String)
    }
    @State private var phase: Phase = .analyzing

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Verify Audio")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("verifySheet.title")

            Text(request.record.filename)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

            switch phase {
            case .analyzing:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking the audio track…")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 20)
                .accessibilityIdentifier("verifySheet.analyzing")

            case .failed(let message):
                Label {
                    Text(message)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
                .accessibilityIdentifier("verifySheet.error")

            case .diagnosed(let diagnosis):
                if diagnosis.isHealthy {
                    healthyView(diagnosis)
                } else {
                    findingsView(diagnosis)
                }
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 600)
        // Runs once per presentation; the probe is @concurrent so the
        // decode never touches the main thread.
        .task { await runDiagnosis() }
    }

    // MARK: Healthy — "All is well" + tech readout

    @ViewBuilder
    private func healthyView(_ diagnosis: AudioVerifyDiagnosis) -> some View {
        Label {
            Text("All is well — the audio track checked out.")
                .font(.body.weight(.medium))
        } icon: {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green)
        }
        .accessibilityIdentifier("verifySheet.allIsWell")

        readoutBox(diagnosis)
    }

    /// The tech readout: codec, sample rate, channels, bit depth,
    /// duration, and the measured per-channel levels. Shown for healthy
    /// files and (when the track was measurable) under findings too.
    /// Frame rate is DELIBERATELY absent — shallow probes misreport it
    /// (see VerifyAudioProbe's file header).
    @ViewBuilder
    private func readoutBox(_ diagnosis: AudioVerifyDiagnosis) -> some View {
        let shape = diagnosis.shape
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                readoutRow("Sound format", shape.audioCodec.isEmpty ? "—" : shape.audioCodec)
                readoutRow("Sample rate", shape.audioSampleRateHz.map { "\($0) Hz" } ?? "—")
                readoutRow("Channels", shape.audioChannels > 0 ? "\(shape.audioChannels)" : "—")
                readoutRow("Bit depth", shape.audioBitDepth.map { "\($0)-bit" } ?? "—")
                readoutRow("Duration", durationText(shape.containerDurationSeconds > 0
                                                    ? shape.containerDurationSeconds
                                                    : shape.audioDurationSeconds))
                if let analysis = diagnosis.balanceAnalysis {
                    Divider()
                    channelLevelRows(analysis.measurements)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func readoutRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
        }
    }

    /// One row per measured channel — same presentation as
    /// BalanceAudioSheet's level rows.
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

    private func durationText(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    // MARK: Findings

    @ViewBuilder
    private func findingsView(_ diagnosis: AudioVerifyDiagnosis) -> some View {
        // Damage headline when the verdict marks the record damaged, so
        // the red catalog row has an obvious source.
        if diagnosis.persistedStatus == "damaged" {
            Label {
                Text("This file's audio is damaged — it's now marked red in the catalog so you can find it again later.")
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundColor(.red)
            }
            .accessibilityIdentifier("verifySheet.damagedHeadline")
        }

        // ForEach over indices: AudioVerifyFinding is Equatable but not
        // Identifiable; the list is tiny and rebuilt per diagnosis.
        ForEach(Array(diagnosis.findings.enumerated()), id: \.offset) { _, finding in
            findingRow(finding, diagnosis: diagnosis)
        }

        // The readout still helps when the track was measurable.
        if diagnosis.balanceAnalysis != nil {
            readoutBox(diagnosis)
        }
    }

    @ViewBuilder
    private func findingRow(_ finding: AudioVerifyFinding,
                            diagnosis: AudioVerifyDiagnosis) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                switch finding {
                case .channelImbalance(let c):
                    Label {
                        Text(c.familyDescription)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "speaker.wave.1")
                            .foregroundColor(.orange)
                    }
                    Text("Balance Audio can fix this — the picture is copied exactly, only the sound is touched, and your original file is never changed.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let analysis = diagnosis.balanceAnalysis {
                        Button("Balance Audio") {
                            startBalance(analysis)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("verifySheet.balanceButton")
                    }

                case .unsupportedCodec(let codec, let decodable):
                    Label {
                        Text(decodable
                             ? "The sound is stored in an old format (\(codec)) that today's Macs can't play."
                             : "The sound track (\(codec.isEmpty ? "unknown format" : codec)) couldn't be read at all — it may be broken.")
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "waveform.badge.exclamationmark")
                            .foregroundColor(.red)
                    }
                    Text("Rebuild Audio Track makes a copy next to the original with the exact same picture and the sound converted to a modern, lossless format. The original is never changed.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Rebuild Audio Track") {
                        startRebuild(finding: finding, diagnosis: diagnosis)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("verifySheet.rebuildButton")

                case .noAudioStream:
                    Label {
                        Text("This file has no sound track at all — only picture.")
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "speaker.slash")
                            .foregroundColor(.secondary)
                    }
                    Text("If its sound exists as a separate file in the catalog, close this window and right-click the row → “Find Matching Audio…” to pair them up.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .referenceMovie(let paths):
                    Label {
                        Text("This isn't a real movie file — it's a pointer that says “play the media over there.” The media it points to isn't inside this file, so there's nothing here to repair.")
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundColor(.red)
                    }
                    if !paths.isEmpty {
                        Text("It points to:")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        ForEach(paths, id: \.self) { path in
                            Text(path)
                                .font(.callout.monospaced())
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                    Text("If those disks or files still exist somewhere, the real media may be recoverable from them — this pointer file itself can be deleted.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .durationMismatch(let audio, let video):
                    Label {
                        Text("The sound track (\(durationText(audio))) is much shorter than the picture (\(durationText(video))) — this audio probably belongs to a different recording.")
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundColor(.red)
                    }
                    Text("Try “Find A/V Pair” on this row to look for the right sound, or Compare/deep-verify before trusting this copy.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .silentAudio:
                    Label {
                        Text("The sound track is there, but it's completely silent — nothing was recorded on it.")
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "speaker.zzz")
                            .foregroundColor(.secondary)
                    }

                case .surround(let channels):
                    Label {
                        Text("This file has surround sound (\(channels) channels). It was checked and left alone — Balance Audio doesn't support surround yet.")
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "hifispeaker.2")
                            .foregroundColor(.secondary)
                    }

                case .multipleProgramTracks(let count):
                    Label {
                        Text("\(count) separate sound tracks in this file carry sound. That's unusual — automatic fixes stay hands-off so nothing good gets overwritten.")
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "waveform")
                            .foregroundColor(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: Actions

    private func runDiagnosis() async {
        let path = request.record.fullPath
        do {
            let diagnosis = try await VerifyAudioProbe.diagnose(path: path)
            phase = .diagnosed(diagnosis)
            persistVerdict(diagnosis)
        } catch AudioVerifyProbeError.toolUnavailable(let detail) {
            phase = .failed(detail)
        } catch AudioVerifyProbeError.probeFailed(let detail) {
            phase = .failed("Could not check the audio — \(detail)")
        } catch is CancellationError {
            // Sheet dismissed mid-probe — nothing to show or persist.
        } catch {
            phase = .failed("Could not check the audio — \(error.localizedDescription)")
        }
    }

    /// Write the verdict onto the record (the persistent damaged
    /// marking the red rows key off) and schedule the debounced save —
    /// same persistence path the Tag menu uses. A failed probe never
    /// writes anything: "couldn't check" is not a verdict.
    private func persistVerdict(_ diagnosis: AudioVerifyDiagnosis) {
        let rec = request.record
        rec.audioVerifyStatus = diagnosis.persistedStatus
        rec.audioVerifyNote = diagnosis.persistedNote
        rec.audioVerifyDate = Date()
        model.saveCatalogDebounced()
    }

    private func startBalance(_ analysis: AudioBalanceAnalysis) {
        fileOpsCenter.startBalanceAudio(record: request.record,
                                        analysis: analysis,
                                        model: model)
        dismiss()
        // Same handoff BalanceAudioSheet uses: open the operations
        // window (progress + Cancel live there) after dismissal starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            openWindow(id: "combine")
        }
    }

    private func startRebuild(finding: AudioVerifyFinding,
                              diagnosis: AudioVerifyDiagnosis) {
        fileOpsCenter.startRebuildAudio(
            record: request.record,
            reason: VerifyAudioRules.noteFragment(for: finding),
            shape: diagnosis.shape,
            model: model)
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            openWindow(id: "combine")
        }
    }
}
