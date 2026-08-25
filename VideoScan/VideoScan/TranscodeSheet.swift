import AppKit
import SwiftUI

struct TranscodeSheet: View {
    @EnvironmentObject private var fileOpsCenter: MediaFileOperationsCenter
    // Forwarded to MediaFileOperationsCenter when the configured job starts.
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject private var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let request: TranscodeRequest

    @State private var preset: TranscodePreset
    @State private var outputFolder: URL?

    init(request: TranscodeRequest) {
        self.request = request
        _preset = State(initialValue: request.initialPreset)
        _outputFolder = State(initialValue: TranscodeDestination.initialDirectory())
    }

    private var outputURL: URL? {
        outputFolder.map {
            TranscodeDestination.outputURL(
                in: $0,
                record: request.record,
                preset: preset
            )
        }
    }

    /// Archived sources default to the archive's OWN year folder (Rick
    /// 2026-08-25: the sticky last-used folder filed Mark's-birthday-1984
    /// edit copy under 1998 and Cape-1992 under 1995). The remembered
    /// folder still wins for anything not in the archive, and the user can
    /// always Choose… elsewhere.
    private func defaultToArchiveYearFolder() {
        let rec = request.record
        let copy = model.isArchiveCopy(rec) ? rec : model.archivedCopy(of: rec)
        guard let copy else { return }
        outputFolder = URL(fileURLWithPath: copy.fullPath).deletingLastPathComponent()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcode Media")
                .font(.headline)
                .accessibilityIdentifier("transcodeSheet.title")
                .onAppear(perform: defaultToArchiveYearFolder)

            GroupBox("Source File") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.record.filename)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                    Text(request.record.fullPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Formatting.humanSize(request.record.sizeBytes))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcode Format")
                        .font(.subheadline.weight(.semibold))
                    Picker("", selection: $preset) {
                        Text("ProRes 422 LT — recommended for VHS")
                            .tag(TranscodePreset.editingLT)
                        Text("ProRes 422 HQ — highest editing data rate")
                            .tag(TranscodePreset.editing)
                        Text("HEVC 10-bit — compact access copy")
                            .tag(TranscodePreset.archival)
                        Text("FFV1 v3 — verified lossless preservation")
                            .tag(TranscodePreset.preservation)
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)

                    Text(preset.configurationDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "externaldrive.fill")
                            .foregroundColor(.orange)
                        Text("Output Folder")
                            .font(.subheadline.weight(.semibold))
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
                        Text("No folder selected")
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    if let outputURL {
                        Text("→ \(outputURL.lastPathComponent)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    if let folder = outputFolder,
                       TranscodeDestination.isSameVolume(
                           source: URL(fileURLWithPath: request.record.fullPath),
                           destinationDirectory: folder
                       ) {
                        Label(
                            "Source and output are on the same volume. Choose another SSD for maximum throughput.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundColor(.yellow)
                    } else {
                        Text("For maximum throughput, choose an SSD different from the source drive.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Transcode") { startTranscode() }
                    .buttonStyle(.borderedProminent)
                    .disabled(outputURL == nil)
                    .keyboardShortcut(.return)
                    .accessibilityIdentifier("transcodeSheet.transcodeButton")
            }
        }
        .padding(20)
        .frame(width: 590)
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Transcode Output Folder"
        panel.message = "Choose a fast SSD, preferably different from the source drive."
        panel.prompt = "Select"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputFolder

        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
            TranscodeDestination.remember(directory: url)
        }
    }

    private func startTranscode() {
        guard let outputFolder, let outputURL else { return }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            let alert = NSAlert()
            alert.messageText = "Replace Existing Transcode?"
            alert.informativeText = outputURL.path
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        TranscodeDestination.remember(directory: outputFolder)
        fileOpsCenter.startTranscode(
            record: request.record,
            preset: preset,
            outputURL: outputURL,
            model: model
        )
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            openWindow(id: "combine")
        }
    }
}
