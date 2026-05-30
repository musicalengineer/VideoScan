import SwiftUI

// MARK: - RelocateSheet
//
// Modal entry point for the Relocate Volume feature. Lets Rick pick a
// source volume root (typically a flaky external HDD), pick a
// destination folder on a healthier drive, optionally preview via
// dry-run, and kick off the migration. See docs/relocate_volume_plan.md
// §7.

private let relocateDestFolderKey = "relocateDestFolder"
private let relocateSourceVolumeKey = "relocateSourceVolume"

struct RelocateSheet: View {

    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) var dismiss

    @State private var sourceVolumePath: String =
        UserDefaults.standard.string(forKey: relocateSourceVolumeKey) ?? "/Volumes/Mini2TB"
    @State private var destinationFolder: URL? = {
        guard let p = UserDefaults.standard.string(forKey: relocateDestFolderKey),
              FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }()
    @State private var dryRun: Bool = false
    @State private var maxConcurrency: Int = 1

    // MARK: - Pre-flight stats (recomputed reactively)

    private var scopedRecords: [VideoRecord] {
        VideoScanModel.recordsScoped(to: sourceVolumePath, in: model.records)
    }

    private var totalBytes: Int64 {
        scopedRecords.reduce(0) { $0 + $1.sizeBytes }
    }

    private var totalBytesString: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    private var freeBytesOnDest: Int64? {
        guard let dest = destinationFolder else { return nil }
        let vals = try? dest.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return vals?.volumeAvailableCapacityForImportantUsage
    }

    private var freeBytesString: String {
        guard let free = freeBytesOnDest else { return "—" }
        return ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
    }

    private var insufficientSpace: Bool {
        guard let free = freeBytesOnDest else { return false }
        return free < totalBytes
    }

    private var sourceVolumeExists: Bool {
        FileManager.default.fileExists(atPath: sourceVolumePath)
    }

    private var canRelocate: Bool {
        !model.isRelocating
            && !model.isReadOnly
            && !scopedRecords.isEmpty
            && destinationFolder != nil
            && sourceVolumeExists
            && !insufficientSpace
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Relocate Volume")
                .font(.headline)
                .accessibilityIdentifier("relocateSheet.title")

            sourceSection
            destinationSection
            optionsSection
            statsSection

            buttonBar
        }
        .padding(20)
        .frame(minWidth: 560)
    }

    // MARK: - Sections

    private var sourceSection: some View {
        GroupBox("Source Volume") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("/Volumes/Mini2TB", text: $sourceVolumePath)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("relocateSheet.sourcePath")
                    .onChange(of: sourceVolumePath) { _, new in
                        UserDefaults.standard.set(new, forKey: relocateSourceVolumeKey)
                    }
                if !sourceVolumeExists {
                    Label("Path does not exist", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            .padding(4)
        }
    }

    private var destinationSection: some View {
        GroupBox("Destination Folder") {
            HStack {
                Image(systemName: "folder.fill").foregroundColor(.orange)
                if let dest = destinationFolder {
                    Text(dest.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("(choose a folder on a healthier drive)")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                Spacer()
                Button("Choose…") { chooseDestinationFolder() }
                    .accessibilityIdentifier("relocateSheet.chooseDest")
            }
            .padding(4)
        }
    }

    private var optionsSection: some View {
        GroupBox("Options") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Dry run (reconcile + preview, no copies)", isOn: $dryRun)
                    .accessibilityIdentifier("relocateSheet.dryRun")
                Stepper(value: $maxConcurrency, in: 1...4) {
                    Text("Concurrent copies: \(maxConcurrency)")
                        .font(.caption)
                }
                .help("Default 1 for flaky HDDs. Raise only when copying SSD → SSD.")
            }
            .padding(4)
        }
    }

    private var statsSection: some View {
        GroupBox("Pre-flight") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("In-scope records:")
                    Spacer()
                    Text("\(scopedRecords.count)")
                        .font(.system(.body, design: .monospaced))
                }
                HStack {
                    Text("Total bytes to copy:")
                    Spacer()
                    Text(totalBytesString)
                        .font(.system(.body, design: .monospaced))
                }
                HStack {
                    Text("Free on destination:")
                    Spacer()
                    Text(freeBytesString)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(insufficientSpace ? .red : .primary)
                }
                if insufficientSpace {
                    Label("Destination does not have enough free space.", systemImage: "exclamationmark.octagon.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            .padding(4)
        }
    }

    private var buttonBar: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.escape)

            let label = dryRun
                ? "Dry Run (\(scopedRecords.count) record(s))"
                : "Relocate \(scopedRecords.count) record(s) (\(totalBytesString))"
            Button(label) { handleRelocate() }
                .buttonStyle(.borderedProminent)
                .disabled(!canRelocate)
                .keyboardShortcut(.return)
                .accessibilityIdentifier("relocateSheet.relocateButton")
        }
    }

    // MARK: - Actions

    private func handleRelocate() {
        guard let dest = destinationFolder else { return }
        let options = RelocateOptions(
            sourceVolumeRootPath: sourceVolumePath,
            destinationRoot: dest,
            maxConcurrency: maxConcurrency,
            dryRun: dryRun,
            skipAlreadyRelocated: true
        )
        model.relocateVolume(options)
        dismiss()
    }

    private func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose destination folder on a healthier drive"
        panel.prompt = "Select"
        if let current = destinationFolder { panel.directoryURL = current }
        if panel.runModal() == .OK, let url = panel.url {
            destinationFolder = url
            UserDefaults.standard.set(url.path, forKey: relocateDestFolderKey)
        }
    }
}
