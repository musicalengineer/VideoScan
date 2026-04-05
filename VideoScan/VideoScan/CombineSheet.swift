import SwiftUI

/// Modal sheet for reviewing and executing batch combine of correlated MXF pairs.
struct CombineSheet: View {
    @EnvironmentObject var model: VideoScanModel
    let selectedIDs: Set<UUID>
    @Environment(\.dismiss) var dismiss

    @State private var outputFolder: URL?

    var pairs: [(video: VideoRecord, audio: VideoRecord)] {
        model.correlatedPairs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Combine Correlated Pairs")
                .font(.headline)

            GroupBox("Correlated Pairs (\(pairs.count))") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(pairs.enumerated()), id: \.offset) { i, pair in
                            HStack(spacing: 4) {
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

            Text("Output: .mov container, stream copy (no re-encode)")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text("Output folder:")
                Text(outputFolder?.path ?? "Not chosen")
                    .foregroundColor(.secondary)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseOutputFolder() }
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

                Button("Combine All") {
                    guard let folder = outputFolder else { return }
                    model.combineAllPairs(outputFolder: folder)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(pairs.isEmpty || outputFolder == nil || model.isCombining)
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 560)
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
