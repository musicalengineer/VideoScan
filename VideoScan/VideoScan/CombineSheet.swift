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
