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
    /// When ON, reconcile classifies records duplicated on other volumes
    /// as safelyRedundant and marks them deleted (catalog-only, with
    /// audit). Default ON — the "failing drive" use case is the common one.
    @State private var skipDupsOnOtherVolumes: Bool = true
    /// Cached reconcile preview, populated by the "Reconcile preview"
    /// button. Used to drive the bucket-summary table + the disclosure
    /// under the safely-redundant toggle.
    @State private var previewResult: ReconcileResult?
    /// True while the reconcile preview is computing off-actor — drives the
    /// inline spinner instead of beachballing the sheet.
    @State private var isPreviewing = false
    /// Handle to the in-flight preview so a re-trigger or an option/source/dest
    /// change can cancel it; the result is applied only if not cancelled.
    @State private var previewTask: Task<Void, Never>?

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
        // Note (§3 Relocate Job Queue — 2026-05-31): we no longer block
        // on `model.isRelocating`. If a job is already running, this
        // Run click adds the new request to the queue instead of
        // starting it immediately. Button label flips to "Add to
        // Queue" so the user knows what's happening.
        !model.isReadOnly
            && !scopedRecords.isEmpty
            && destinationFolder != nil
            && sourceVolumeExists
            && !insufficientSpace
    }

    /// Bytes that would be saved by the safelyRedundant rule, summed
    /// from the preview result. Zero when no preview has been run yet
    /// or when nothing matched.
    private var redundantBytes: Int64 {
        previewResult?.safelyRedundant.reduce(0) { $0 + $1.rec.sizeBytes } ?? 0
    }

    private var redundantBytesString: String {
        ByteCountFormatter.string(fromByteCount: redundantBytes, countStyle: .file)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Migrate Volume")
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
                // TextField + Browse button. The field stays editable for
                // power users / typed network paths (smb://host/share/…
                // when not pre-mounted under /Volumes). The Browse button
                // matches the same NSOpenPanel pattern used in the rest of
                // the app (CombineSheet, PersonFinderView, etc.).
                HStack(spacing: 8) {
                    TextField("/Volumes/Mini2TB", text: $sourceVolumePath)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("relocateSheet.sourcePath")
                        .onChange(of: sourceVolumePath) { _, new in
                            UserDefaults.standard.set(new, forKey: relocateSourceVolumeKey)
                            // Source change invalidates any prior preview.
                            invalidatePreview()
                        }
                    Button("Browse…") { chooseSourceVolume() }
                        .accessibilityIdentifier("relocateSheet.browseSource")
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

                // The headline "failing-drive escape hatch" option.
                Toggle("Skip duplicates already on other volumes",
                       isOn: $skipDupsOnOtherVolumes)
                    .accessibilityIdentifier("relocateSheet.skipDupsOnOtherVolumes")
                    .help("When ON, files already present (same size + hash) on a volume other than source or destination are marked deleted in the catalog with a witness audit trail, instead of being copied. The source file is never touched.")

                // Disclosure: populated only after a preview run.
                if let preview = previewResult {
                    let n = preview.safelyRedundant.count
                    Text("\(n) file\(n == 1 ? "" : "s"), \(redundantBytesString) redundant")
                        .font(.caption)
                        .foregroundColor(skipDupsOnOtherVolumes ? .green : .secondary)
                        .padding(.leading, 22)
                        .accessibilityIdentifier("relocateSheet.redundantDisclosure")
                } else {
                    Text("Run the Reconcile preview to see how many files are already mirrored elsewhere.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 22)
                }

                Stepper(value: $maxConcurrency, in: 1...4) {
                    Text("Concurrent copies: \(maxConcurrency)")
                        .font(.caption)
                }
                .help("Default 1 for flaky HDDs. Raise only when copying SSD → SSD.")
            }
            .padding(4)
        }
        .onChange(of: skipDupsOnOtherVolumes) { _, _ in
            // Toggle change invalidates the preview — the bucket counts
            // will differ depending on whether E is enabled.
            invalidatePreview()
        }
    }

    private var statsSection: some View {
        GroupBox("Pre-flight") {
            VStack(alignment: .leading, spacing: 4) {
                // Heads-up explanatory line above the bucket summary.
                Text("Operates on catalogued videos only. Photos, documents, and project files are not touched — handle those separately.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
                    .accessibilityIdentifier("relocateSheet.scopeNotice")

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

                Divider().padding(.vertical, 4)

                // Reconcile preview + bucket summary.
                HStack(spacing: 8) {
                    Button("Reconcile preview") { runPreview() }
                        .disabled(isPreviewing || scopedRecords.isEmpty || destinationFolder == nil)
                        .accessibilityIdentifier("relocateSheet.reconcilePreview")
                    if isPreviewing {
                        ProgressView().controlSize(.small)
                        Text("Scanning & matching files…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .accessibilityIdentifier("relocateSheet.previewSpinner")
                    } else if previewResult != nil {
                        Text("(\(scopedRecords.count) records classified)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                if let preview = previewResult {
                    bucketSummaryRows(preview)
                }
            }
            .padding(4)
        }
    }

    /// Compact bucket summary table. Mirrors the labels we use in the
    /// console log so the user sees consistent terminology across the
    /// preview and the live run.
    private func bucketSummaryRows(_ r: ReconcileResult) -> some View {
        let readyBytes = r.ready.reduce(0) { $0 + $1.sizeBytes }
        let readyBytesString = ByteCountFormatter.string(fromByteCount: readyBytes, countStyle: .file)
        let nRedundant = r.safelyRedundant.count
        return VStack(alignment: .leading, spacing: 2) {
            bucketRow("Ready to migrate", count: r.ready.count, detail: readyBytesString)
            bucketRow("Already at destination", count: r.adopted.count, detail: "adopt without copy")
            // The headline new row — surfaced prominently regardless of
            // current toggle state so Rick can see the magnitude before
            // committing.
            bucketRow("Safely redundant",
                      count: nRedundant,
                      detail: "\(redundantBytesString) — will mark as deleted with audit trail",
                      identifier: "relocateSheet.bucket.safelyRedundant",
                      emphasized: nRedundant > 0)
            bucketRow("Source-side moves", count: r.sourceSideMoves.count, detail: "paths rewritten")
            bucketRow("Manually deleted", count: r.manuallyDeleted.count, detail: "marked, kept for audit")
            bucketRow("Previously migrated", count: r.previouslyRelocated.count, detail: "skipped")
        }
        .padding(.top, 4)
    }

    private func bucketRow(_ label: String,
                           count: Int,
                           detail: String,
                           identifier: String? = nil,
                           emphasized: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 180, alignment: .leading)
            Text("\(count)")
                .font(.system(.body, design: .monospaced))
                .frame(width: 50, alignment: .trailing)
                .foregroundColor(emphasized ? .green : .primary)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .accessibilityIdentifier(identifier ?? "")
    }

    private var buttonBar: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.escape)

            // Context-aware label: "Add to Queue" when something else
            // is already running (the Run click slips into the queue);
            // "Run / Dry Run" otherwise. The Jobs panel toolbar button
            // surfaces the depth so the user can verify their adds.
            let busy = model.isRelocating
            let label: String = {
                if dryRun {
                    return busy
                        ? "Add Dry Run to Queue (\(scopedRecords.count) record(s))"
                        : "Dry Run (\(scopedRecords.count) record(s))"
                }
                let base = "\(scopedRecords.count) record(s) (\(totalBytesString))"
                return busy ? "Add to Queue — \(base)" : "Migrate \(base)"
            }()
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
            skipAlreadyRelocated: true,
            skipDupsOnOtherVolumes: skipDupsOnOtherVolumes
        )
        model.relocateVolume(options)
        dismiss()
    }

    /// Browse panel for the source volume. Mirrors `chooseDestinationFolder`
    /// — same NSOpenPanel pattern the rest of the app uses (CombineSheet,
    /// PersonFinderView, ScanJobRow). Cuts down on typos when picking a
    /// `/Volumes/...` root, and surfaces mounted SMB/AFP shares in the
    /// panel's Locations sidebar for free. The TextField is still editable
    /// for typed paths (e.g. an unmounted share root).
    private func chooseSourceVolume() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false  // source is an existing volume — don't offer to make one
        panel.allowsMultipleSelection = false
        panel.message = "Choose source volume root (e.g. /Volumes/Mini2TB)"
        panel.prompt = "Select"
        // Seed the panel at /Volumes so the mounted-drives picker is the
        // first thing Rick sees.
        if sourceVolumeExists {
            panel.directoryURL = URL(fileURLWithPath: sourceVolumePath)
        } else {
            panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        }
        if panel.runModal() == .OK, let url = panel.url {
            sourceVolumePath = Self.normalizeSourcePath(url.path)
            UserDefaults.standard.set(sourceVolumePath, forKey: relocateSourceVolumeKey)
            invalidatePreview()  // source change invalidates preview
        }
    }

    /// Strip a single trailing slash from a picked path so the value we
    /// store matches the typed-input convention (`/Volumes/Mini2TB`, not
    /// `/Volumes/Mini2TB/`). `recordsScoped` is tolerant of either form,
    /// but keeping the stored UserDefault clean avoids surprising the
    /// user the next time the sheet opens. The root `/` itself is
    /// preserved untouched — defensive against a pathological pick.
    ///
    /// Swift's `static func` on a struct ≈ a free function namespaced in
    /// C++; pure helper for testability.
    static func normalizeSourcePath(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
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
            invalidatePreview()  // dest change invalidates preview
        }
    }

    /// Reconcile preview. The FS walk + per-file hashing runs OFF the main
    /// actor (Task.detached) so the sheet shows a spinner instead of
    /// beachballing while it thinks — the same fix applied to the live run's
    /// reconcile. Inputs are snapshotted on the main actor; the result is
    /// applied back on the main actor only if a re-trigger or an
    /// option/source/dest change hasn't cancelled this Task in the meantime.
    private func runPreview() {
        guard let dest = destinationFolder else { return }
        let scope = scopedRecords
        let allRecords = model.records          // value-type (COW) snapshot — cheap
        let src = sourceVolumePath
        let skipDups = skipDupsOnOtherVolumes

        previewTask?.cancel()
        isPreviewing = true
        previewTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ReconcileResult in
                let sourceFiles = Self.enumerateFiles(at: src)
                let destFiles = Self.enumerateFiles(at: dest.path)
                return RelocateReconcile.reconcile(
                    records: scope,
                    allCatalogRecords: allRecords,
                    sourceVolumeRootPath: src,
                    destinationRoot: dest,
                    sourceFiles: sourceFiles,
                    destFiles: destFiles,
                    skipDupsOnOtherVolumes: skipDups,
                    hash: { FileHasher.partialMD5(path: $0) }
                )
            }.value
            if Task.isCancelled { return }   // superseded by a newer preview/invalidation
            previewResult = result
            isPreviewing = false
        }
    }

    /// Clear any cached preview and stop an in-flight one. Called whenever an
    /// input that feeds the reconcile (source, dest, skip-dups) changes, so a
    /// stale preview can never be applied after the inputs moved.
    private func invalidatePreview() {
        previewTask?.cancel()
        previewTask = nil
        isPreviewing = false
        previewResult = nil
    }

    /// Mirror of VideoScanModel.enumerateFiles — local copy because that
    /// helper is `private` to the model extension. Walks `root` and
    /// returns (path, size) for every regular file under it. Returns []
    /// when the path doesn't exist (e.g. dest folder hasn't been created
    /// yet). `nonisolated static` so the preview Task can run it off-actor.
    nonisolated private static func enumerateFiles(at root: String) -> [ReconcileFileEntry] {
        guard FileManager.default.fileExists(atPath: root) else { return [] }
        let fm = FileManager.default
        guard let it = fm.enumerator(atPath: root) else { return [] }
        var out: [ReconcileFileEntry] = []
        while let rel = it.nextObject() as? String {
            let path = (root as NSString).appendingPathComponent(rel)
            var sb = stat()
            guard stat(path, &sb) == 0 else { continue }
            if (sb.st_mode & S_IFMT) != S_IFREG { continue }
            out.append(.init(path: path, size: Int64(sb.st_size)))
        }
        return out
    }
}
