import SwiftUI

/// Modal sheet for reviewing and executing batch combine of correlated MXF pairs.
struct CombineSheet: View {
    @EnvironmentObject var model: VideoScanModel
    let selectedIDs: Set<UUID>
    @Environment(\.dismiss) var dismiss

    @State private var outputFolder: URL?
    @State private var checkedPairs: Set<Int> = []

    var pairs: [(video: VideoRecord, audio: VideoRecord)] {
        model.correlatedPairs
    }

    private var allChecked: Bool { checkedPairs.count == pairs.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Combine Correlated Pairs")
                .font(.headline)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Correlated Pairs (\(pairs.count))")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button(allChecked ? "Select None" : "Select All") {
                            if allChecked {
                                checkedPairs.removeAll()
                            } else {
                                checkedPairs = Set(0..<pairs.count)
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)

                        if !checkedPairs.isEmpty {
                            Text("\(checkedPairs.count) selected")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.green)
                        }
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(pairs.enumerated()), id: \.offset) { i, pair in
                                HStack(spacing: 4) {
                                    Toggle("", isOn: Binding(
                                        get: { checkedPairs.contains(i) },
                                        set: { on in
                                            if on { checkedPairs.insert(i) }
                                            else  { checkedPairs.remove(i) }
                                        }
                                    ))
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()

                                    Text("\(i + 1).")
                                        .foregroundColor(.secondary)
                                        .frame(width: 24, alignment: .trailing)
                                    Image(systemName: "film")
                                        .foregroundColor(.blue)
                                    Text(pair.video.filename)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                    Text("+")
                                        .foregroundColor(.secondary)
                                    Image(systemName: "waveform")
                                        .foregroundColor(.orange)
                                    Text(pair.audio.filename)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 200)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundColor(.orange)
                        Text("Output Folder")
                            .font(.headline)
                        Spacer()
                        Button("Choose…") { chooseOutputFolder() }
                    }
                    if let folder = outputFolder {
                        Text(folder.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("No folder selected — click Choose to set output destination")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    Text("Each pair creates {video_filename}_combined.mov — stream copy, no re-encode")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(4)
            }

            if model.isCombining {
                CompactDashboard(
                    dashboard: model.dashboard,
                    isScanning: false,
                    isCombining: true,
                    isExpanded: .constant(false)
                )
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)

                Button("Combine \(checkedPairs.count == pairs.count ? "All" : "\(checkedPairs.count)") Pair\(checkedPairs.count == 1 ? "" : "s")") {
                    guard let folder = outputFolder else { return }
                    let selectedPairs = checkedPairs.sorted().compactMap { i in
                        i < pairs.count ? pairs[i] : nil
                    }
                    model.combineSelectedPairs(selectedPairs, outputFolder: folder)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(checkedPairs.isEmpty || outputFolder == nil || model.isCombining)
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            // Default: all pairs checked
            checkedPairs = Set(0..<pairs.count)
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose output folder for combined files"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
        }
    }
}

// MARK: - Combine Single Pair Sheet

/// Focused dialog for combining one correlated A/V pair.
struct CombinePairSheet: View {
    @EnvironmentObject var model: VideoScanModel
    let video: VideoRecord
    let audio: VideoRecord
    @Environment(\.dismiss) var dismiss

    @State private var outputFolder: URL?
    @State private var status: CombinePairStatus = .ready
    @State private var errorMessage: String = ""

    enum CombinePairStatus {
        case ready, combining, done, failed
    }

    private var outputFilename: String {
        let stem = (video.filename as NSString).deletingPathExtension
        return "\(stem)_combined.mov"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Combine Pair")
                .font(.headline)

            GroupBox("Source Files") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "film")
                            .foregroundColor(.blue)
                            .frame(width: 16)
                        Text("Video")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .trailing)
                        Text(video.filename)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(video.fullPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .padding(.leading, 62)

                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .foregroundColor(.green)
                            .frame(width: 16)
                        Text("Audio")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .trailing)
                        Text(audio.filename)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(audio.fullPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .padding(.leading, 62)
                }
                .padding(4)
            }

            GroupBox("Output") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundColor(.orange)
                        if let folder = outputFolder {
                            Text(folder.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("No output folder selected")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        Spacer()
                        Button("Choose…") { chooseOutputFolder() }
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "doc.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 10))
                        Text(outputFilename)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                    Text("Stream copy — no re-encode (fast)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(4)
            }

            if status == .combining {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Combining…")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            if status == .done {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Combined successfully!")
                        .font(.callout.weight(.medium))
                        .foregroundColor(.green)
                }
            }
            if status == .failed {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text("Combine failed")
                            .font(.callout.weight(.medium))
                            .foregroundColor(.red)
                    }
                    if !errorMessage.isEmpty {
                        ScrollView {
                            Text(errorMessage)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.red)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 100)
                        .background(Color.red.opacity(0.05))
                        .cornerRadius(4)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)

                if status == .done {
                    Button("Reveal in Finder") {
                        if let folder = outputFolder {
                            let path = folder.appendingPathComponent(outputFilename).path
                            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return)
                } else {
                    Button("Combine") { runCombine() }
                        .buttonStyle(.borderedProminent)
                        .disabled(outputFolder == nil || status == .combining)
                        .keyboardShortcut(.return)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func runCombine() {
        guard let folder = outputFolder else { return }

        // Validate paths before invoking ffmpeg
        let vPath = video.fullPath
        let aPath = audio.fullPath
        if vPath.isEmpty || aPath.isEmpty {
            status = .failed
            errorMessage = "Missing file path:\n  video.fullPath = \"\(vPath)\"\n  audio.fullPath = \"\(aPath)\""
            return
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: vPath) {
            status = .failed
            errorMessage = "Video file not found:\n\(vPath)"
            return
        }
        if !fm.fileExists(atPath: aPath) {
            status = .failed
            errorMessage = "Audio file not found:\n\(aPath)"
            return
        }

        status = .combining
        errorMessage = ""
        let outputPath = folder.appendingPathComponent(outputFilename).path

        Task {
            let result = await CombineEngine.runFFMpeg(
                videoPath: vPath,
                audioPath: aPath,
                outputPath: outputPath,
                log: { msg in model.log(msg) }
            )
            await MainActor.run {
                if result.success {
                    status = .done
                    model.log("✓ Combined: \(outputFilename)")
                } else {
                    status = .failed
                    // Extract the last meaningful error line from stderr
                    let lastErrors = result.stderr
                        .components(separatedBy: "\n")
                        .filter { !$0.isEmpty }
                        .suffix(5)
                        .joined(separator: "\n")
                    errorMessage = "ffmpeg exit code \(result.exitCode)\n\(lastErrors)"
                    model.log("✗ Failed: \(outputFilename) — exit \(result.exitCode)")
                    model.log(lastErrors)
                }
            }
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose output folder for combined file"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
        }
    }
}
