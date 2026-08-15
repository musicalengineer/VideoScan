import SwiftUI

// MARK: - Verification Results sheet
//
// GH #128 originally ran the diagnosis INSIDE this sheet — but the
// levels pass decodes the whole audio track (minutes on long tapes) and
// the sheet is window-modal, so the catalog sat blocked (GH #135, Rick
// 2026-07-24). The diagnosis now ALWAYS runs as a VerifyAudioJob in the
// Media File Operations window; this sheet is purely the RESULTS
// presentation: it renders an ALREADY-COMPUTED AudioVerifyDiagnosis
// (from the Center's session cache) instantly — no probe, no levels
// decode, nothing to wait for. The compiler enforces that contract:
// `VerifyAudioRequest.diagnosis` is non-optional, so a pre-diagnosis
// presentation is unrepresentable.
//
// GH #137 (Rick 2026-07-25): Verify Audio is now the SINGLE entry point
// for examining audio — the standalone "Balance Audio…" catalog verb
// and its analyze-from-scratch sheet are retired. Everything that sheet
// promised before dispatching the render now lives on this sheet's
// channel-imbalance finding: what the fix will do, the raw-DV container
// note, the dropped-silent-tracks note, and the planned destination
// name. The Balance button dispatches the render with the diagnosis's
// already-computed analysis — a fresh decode is unrepresentable here
// too (`startBalanceAudio(record:fromDiagnosis:model:plannedOutput:)`
// reads `diagnosis.balanceAnalysis`, it cannot probe).
//
// The verdict was already persisted by the job (audioVerifyStatus /
// audioVerifyNote / audioVerifyDate) — this sheet writes nothing.
//
// Presented via `.sheet(item:)` from the catalog row context menu
// ("Verification Results…") — NEVER chained isPresented sheets
// (documented antipattern).
//
// Text sizes are deliberately generous (.title2/.body, nothing smaller
// than .callout) — large readable text is an accessibility need here,
// not polish.

/// A pending results presentation. Fresh ID per menu click. Carries the
/// record AND its computed diagnosis — the diagnosis is required, which
/// is what guarantees this sheet can never block on a probe.
struct VerifyAudioRequest: Identifiable {
    let id = UUID()
    let record: VideoRecord
    let diagnosis: AudioVerifyDiagnosis
    let onFindMatchingAudio: () -> Void
}

/// Runs catalog actions only after the results sheet starts dismissing.
/// The injected scheduler keeps this ordering unit-testable without UI tests.
@MainActor
enum VerifyAudioDismissHandoff {
    typealias Scheduler = (@escaping () -> Void) -> Void

    static func perform(
        dismiss: () -> Void,
        action: @escaping () -> Void,
        schedule: Scheduler = { action in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                action()
            }
        }
    ) {
        dismiss()
        schedule(action)
    }
}

struct VerifyAudioSheet: View {
    @EnvironmentObject private var fileOpsCenter: MediaFileOperationsCenter
    // Passed whole into startBalanceAudio/startRebuildAudio (the repair
    // dispatches) — no property reads here, and that's intentional.
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject private var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let request: VerifyAudioRequest

    /// Planned `<stem>_balanced.<ext>` beside the original, container-
    /// aware (raw DV publishes as .mov). Computed ONCE per presentation
    /// in `.task` — `balancedOutputURL` uniquifies against files on
    /// disk, and that little bit of I/O doesn't belong in `body`. The
    /// SAME URL is displayed and handed to the render job (the m3
    /// convention: never show a name the job won't plan to use).
    @State private var plannedBalanceDestination: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Audio Information")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("verifySheet.title")

            Text(request.record.filename)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

            if request.diagnosis.isHealthy {
                healthyView(request.diagnosis)
            } else {
                findingsView(request.diagnosis)
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
        .task {
            // Only the actionable imbalance path shows a destination.
            guard let analysis = request.diagnosis.balanceAnalysis,
                  request.diagnosis.findings.contains(where: {
                      if case .channelImbalance = $0 { return true }
                      return false
                  }) else { return }
            plannedBalanceDestination = BalanceAudioFix.balancedOutputURL(
                forSourcePath: request.record.fullPath,
                containerFormat: analysis.shape.containerFormat)
        }
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
                Text("This file's audio is damaged — it's marked red in the catalog so you can find it again later.")
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
                    channelImbalanceRow(c, diagnosis: diagnosis)

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
                    Text("If its sound exists as a separate file in the catalog, VideoScan can look for the best match and prepare the pair.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Find Matching Audio…") {
                        startFindMatchingAudio()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("verifySheet.findMatchingAudioButton")

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

    /// The channel-imbalance finding — since GH #137 this row IS the
    /// Balance Audio offer, carrying everything the retired standalone
    /// sheet promised before its Balance button: the finding, what the
    /// fix will do, the raw-DV wrapper note, the dropped-silent-tracks
    /// note, the never-touch-the-original promise, and the planned
    /// destination name.
    @ViewBuilder
    private func channelImbalanceRow(_ c: AudioChannelClass,
                                     diagnosis: AudioVerifyDiagnosis) -> some View {
        Label {
            Text(c.familyDescription)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "speaker.wave.1")
                .foregroundColor(.orange)
        }

        if let analysis = diagnosis.balanceAnalysis {
            Label {
                Text(fixDescription(c))
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
            if BalanceAudioFix.isRawDVContainer(analysis.shape.containerFormat) {
                // Honest about the wrapper change: the raw DV file
                // can't hold the balanced sound, so the copy is
                // QuickTime — the video inside is the same untouched DV.
                Label {
                    Text("This raw DV file can't hold the balanced sound, so the copy is packaged as QuickTime (.mov). The DV picture inside is untouched.")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "shippingbox")
                        .foregroundColor(.accentColor)
                }
                .accessibilityIdentifier("verifySheet.dvContainerNote")
            }
            if !analysis.droppedStreamIndices.isEmpty {
                // "won't be used", not "removed": accurate for every
                // container (QuickTime genuinely drops the pair; other
                // muxers with fixed audio slots may keep an empty one).
                Label {
                    Text(analysis.droppedStreamIndices.count == 1
                         ? "The tape's extra silent track won't be used in the balanced copy."
                         : "The tape's extra silent tracks won't be used in the balanced copy.")
                        .font(.body)
                } icon: {
                    Image(systemName: "speaker.slash.fill")
                        .foregroundColor(.secondary)
                }
            }
            Label {
                Text("Your original file is never changed.")
                    .font(.body.weight(.medium))
            } icon: {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(.green)
            }
            if let destination = plannedBalanceDestination {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("The balanced copy will be saved next to it as:")
                            .font(.body)
                        Text(destination.lastPathComponent)
                            .font(.body.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } icon: {
                    Image(systemName: "doc.badge.plus")
                        .foregroundColor(.accentColor)
                }
            }
            Button("Balance Audio") {
                startBalance(diagnosis)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("verifySheet.balanceButton")
        }
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

    private func startFindMatchingAudio() {
        // regression: presenting the pair sheet or alert before this sheet
        // dismisses races SwiftUI's modal state machine.
        VerifyAudioDismissHandoff.perform(
            dismiss: { dismiss() },
            action: request.onFindMatchingAudio)
    }

    private func startBalance(_ diagnosis: AudioVerifyDiagnosis) {
        fileOpsCenter.startBalanceAudio(record: request.record,
                                        fromDiagnosis: diagnosis,
                                        model: model,
                                        plannedOutput: plannedBalanceDestination)
        dismiss()
        // Same handoff CleanupSheet uses: open the operations window
        // (progress + Cancel live there) after the dismissal starts.
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
