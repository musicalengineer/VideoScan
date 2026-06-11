import SwiftUI

// MARK: - RipAllFramesSheet
//
// Pre-flight options for "Extract Frames…" (the ffmpeg-only verb,
// split from "Extract Facial Frames…" 2026-06-10). Exists for ONE
// reason: this verb can be a disk bomb — a 10-minute DV tape at full
// rate is ~18,000 PNGs and several GB. So before anything starts, the
// user sees a live estimated frame count + disk usage for the chosen
// sampling mode, plus the free space on the destination volume.
//
// Pattern: single sheet with an in-sheet destination picker (the
// CombinePairSheet precedent) rather than NSOpenPanel-then-start (the
// facial ripper's flow) — the estimate needs a destination to check
// free space against, and defaulting to the video's own parent folder
// makes the common case one click. Output lands in
// "<parent>/<stem>-allframes/" — distinct suffix, never collides with
// the facial ripper's "<stem>-frames/".
//
// Presented via .sheet(item:) from the catalog context menu (the
// chained-sheet antipattern memo: item-driven sheets only).

struct RipAllFramesSheet: View {
    @EnvironmentObject var fileOpsCenter: MediaFileOperationsCenter
    let record: VideoRecord
    @Environment(\.dismiss) var dismiss
    @Environment(\.openWindow) var openWindow

    /// Local picker tag — maps to AllFramesRipPlanner.Sampling with the
    /// stepper values folded in (Picker tags want a simple Hashable).
    private enum Mode: Hashable {
        case every, nth, fps
    }

    @State private var mode: Mode = .every
    /// "Every Nth frame" stepper value. 10 is a sane starting point
    /// (~3/sec on NTSC) — the user picked this mode to thin the output.
    @State private var nthStep = 10
    /// "Frames per second" stepper value. 1/sec is the classic
    /// contact-sheet rate.
    @State private var targetFPS = 1
    /// Destination parent folder. Defaults to the video's own folder.
    @State private var destinationParent: URL?

    init(record: VideoRecord) {
        self.record = record
        let parent = URL(fileURLWithPath: record.fullPath).deletingLastPathComponent()
        _destinationParent = State(initialValue: parent)
    }

    // MARK: Derived sampling + estimates (recomputed on every control
    // change — all pure arithmetic via AllFramesRipPlanner, no I/O
    // except the one free-space statfs below)

    private var sampling: AllFramesRipPlanner.Sampling {
        switch mode {
        case .every: return .everyFrame
        case .nth: return .everyNth(step: nthStep)
        case .fps: return .framesPerSecond(fps: targetFPS)
        }
    }

    private var sourceFPS: Double? {
        AllFramesRipPlanner.sourceFPS(fromCatalogString: record.frameRate)
    }

    private var estimatedFrames: Int? {
        AllFramesRipPlanner.estimatedFrames(durationSeconds: record.durationSeconds,
                                            sourceFPS: sourceFPS,
                                            sampling: sampling)
    }

    private var estimatedBytes: Int64? {
        AllFramesRipPlanner.estimatedTotalBytes(frames: estimatedFrames,
                                                resolution: record.resolution)
    }

    private var freeSpaceBytes: Int64? {
        guard let folder = destinationParent else { return nil }
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage { return free }
        let vals2 = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return vals2?.volumeAvailableCapacity.map { Int64($0) }
    }

    private var insufficientSpace: Bool {
        guard let est = estimatedBytes, let free = freeSpaceBytes else { return false }
        return est > free
    }

    private var outputFolderName: String {
        let stem = (record.filename as NSString).deletingPathExtension
        return AllFramesRipPlanner.destinationDirName(forStem: stem)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Extract Frames")
                    .font(.headline)
                Text(record.filename)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            samplingSection
            estimateSection
            destinationSection
            buttonBar
        }
        .padding(20)
        .frame(width: 540)
    }

    // MARK: Sampling

    private var samplingSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Frames to Export")
                    .font(.subheadline.weight(.semibold))

                Picker("", selection: $mode) {
                    Text("Every frame").tag(Mode.every)
                    Text("Every Nth frame").tag(Mode.nth)
                    Text("Frames per second").tag(Mode.fps)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("ripAllFrames.samplingPicker")

                switch mode {
                case .every:
                    Text("One PNG per source frame — full takes, biggest output. Check the estimate below.")
                        .font(.caption).foregroundColor(.secondary)
                case .nth:
                    HStack(spacing: 8) {
                        Stepper(value: $nthStep, in: 2...100) {
                            Text("Keep 1 of every \(nthStep) frames")
                                .font(.system(size: 12))
                        }
                        .accessibilityIdentifier("ripAllFrames.nthStepper")
                        if let fps = sourceFPS {
                            Text(String(format: "≈ %.1f/sec", fps / Double(nthStep)))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                case .fps:
                    Stepper(value: $targetFPS, in: 1...60) {
                        Text("\(targetFPS) frame\(targetFPS == 1 ? "" : "s") per second")
                            .font(.system(size: 12))
                    }
                    .accessibilityIdentifier("ripAllFrames.fpsStepper")
                }
            }
            .padding(4)
        }
    }

    // MARK: Estimate (the disk-bomb guard)

    private var estimateSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 16) {
                    estimateStat(label: "Est. frames",
                                 value: estimatedFrames.map { "~\($0.formatted())" } ?? "unknown")
                    estimateStat(label: "Est. disk usage",
                                 value: estimatedBytes.map { "~" + Formatting.humanSize($0) } ?? "unknown")
                    if let free = freeSpaceBytes {
                        estimateStat(label: "Free space",
                                     value: Formatting.humanSize(free),
                                     valueColor: insufficientSpace ? .red : .green)
                    }
                    Spacer()
                }

                if insufficientSpace {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 11))
                        Text("Estimated output exceeds free space on the destination volume.")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.red)
                    }
                } else if estimatedFrames == nil {
                    Text("Duration or frame-rate metadata is missing for this file — the export will run with indeterminate progress.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    Text("Estimates from cataloged metadata (PNG sizes vary with content).")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(4)
        }
    }

    private func estimateStat(label: String, value: String,
                              valueColor: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(valueColor)
        }
    }

    // MARK: Destination

    private var destinationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.orange)
                    Text("Destination")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Choose…") { chooseDestination() }
                }
                if let parent = destinationParent {
                    Text(parent.appendingPathComponent(outputFolderName).path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Frames are written into this new subfolder")
                } else {
                    Text("No folder selected")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(4)
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Pick the parent folder. A subfolder named \"\(outputFolderName)\" will be created inside."
        panel.prompt = "Select"
        if let current = destinationParent { panel.directoryURL = current }
        if panel.runModal() == .OK, let url = panel.url {
            destinationParent = url
        }
    }

    // MARK: Buttons

    private var buttonBar: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.escape)
            Button(startButtonLabel) { startExport() }
                .buttonStyle(.borderedProminent)
                .disabled(destinationParent == nil || insufficientSpace)
                .keyboardShortcut(.return)
                .accessibilityIdentifier("ripAllFrames.startButton")
        }
    }

    private var startButtonLabel: String {
        if let frames = estimatedFrames {
            return "Extract ~\(frames.formatted()) Frames"
        }
        return "Extract Frames"
    }

    private func startExport() {
        guard let parent = destinationParent else { return }
        let options = AllFramesRipper.Options(sampling: sampling,
                                              estimatedFrames: estimatedFrames,
                                              estimatedBytes: estimatedBytes)
        fileOpsCenter.startRipAllFrames(record: record,
                                        destinationParent: parent,
                                        options: options)
        dismiss()
        // Same dismiss-then-open beat as CombinePairSheet — opening the
        // window while the sheet is still up loses key focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            openWindow(id: "combine")
        }
    }
}
