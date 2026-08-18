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
    /// Rick 2026-08-17: the destination must be HIS choice. When on, a
    /// chosen volume root gets from_<SourceVolume>/<subtree> beneath it;
    /// when off, the chosen folder is used exactly as chosen. Remembered.
    @AppStorage("relocate.preserveSourceLayout") private var preserveSourceLayout: Bool = true
    /// The folder as the user picked it (before any layout derivation).
    @State private var chosenDestinationRoot: URL?
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

    /// Live (done, total) from the preview's classify loop — nil while
    /// enumerating or when idle. Drives the determinate narration next to
    /// the preview spinner (2026-07-06 honest-progress fix).
    @State private var previewProgress: (done: Int, total: Int)?

    // MARK: - Pre-flight stats (cached — 2026-07-06 livelock fix)
    //
    // These were COMPUTED properties running a full-catalog PathScope
    // sweep per access — and one body evaluation reads them ~9 times.
    // At 103k records that's ~a second of scanning per render, so every
    // @Published model change ground the modal into a livelock (the
    // "dry run that never starts" Rick hit on LACIE500). Same class as
    // the VolumesWindow beachball: NO O(records) work in view bodies.
    // Cached on appear + debounced source-path edits; the real migrate/
    // preview re-derives its own scope at run time regardless.

    @State private var cachedScope: [VideoRecord] = []
    @State private var cachedTotalBytes: Int64 = 0
    @State private var scopeRefreshTask: Task<Void, Never>?

    private var scopedRecords: [VideoRecord] { cachedScope }

    private var totalBytes: Int64 { cachedTotalBytes }

    private func refreshScopeStats() {
        cachedScope = VideoScanModel.recordsScoped(to: sourceVolumePath, in: model.records)
        cachedTotalBytes = cachedScope.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Debounced refresh for TextField edits — one sweep 250 ms after
    /// typing settles, not one per keystroke.
    private func scheduleScopeRefresh() {
        scopeRefreshTask?.cancel()
        scopeRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            refreshScopeStats()
        }
    }

    /// Bytes the run will actually copy (GH #162 follow-up, 2026-08-18):
    /// the preview plan's ready + source-move bytes when a preview exists,
    /// else the whole scope as an honest upper bound. Drives BOTH the
    /// "bytes to copy" row and the free-space check — the old whole-scope
    /// figure could block a migrate (or scare Rick) over bytes that were
    /// never going to move (adopt / safely-redundant / deleted).
    private var bytesToCopy: (bytes: Int64, label: String) {
        ReconcileLogLines.bytesToCopy(scopeBytes: totalBytes, plan: previewResult)
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
        return free < bytesToCopy.bytes
    }

    private var sourceVolumeExists: Bool {
        FileManager.default.fileExists(atPath: sourceVolumePath)
    }

    /// Destination equal to, inside, or containing the source is never a
    /// migration (Rick 2026-08-17: a job ran with dest == source and
    /// reported "done" having copied nothing). nil = fine; else the reason.
    static func destinationProblem(source: String, destination: URL?) -> String? {
        guard let dest = destination else { return nil }
        let src = URL(fileURLWithPath: source).standardizedFileURL.path
        let dst = dest.standardizedFileURL.path
        if src == dst { return "The destination is the source folder itself — choose a different volume or folder." }
        if dst.hasPrefix(src + "/") { return "The destination is inside the source — that would copy the folder into itself." }
        if src.hasPrefix(dst + "/") { return "The destination contains the source — files are already there; choose a different folder." }
        return nil
    }

    private var destinationProblemText: String? {
        Self.destinationProblem(source: sourceVolumePath, destination: destinationFolder)
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
            && destinationProblemText == nil
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
        .onAppear { refreshScopeStats() }
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
                            scheduleScopeRefresh()
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
        GroupBox("Destination") {
            HStack {
                Image(systemName: "folder.fill").foregroundColor(.orange)
                if let dest = destinationFolder {
                    Text(dest.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("(choose the destination volume — the app builds from_<Source>/<subtree>)")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                Spacer()
                Button("Choose…") { chooseDestinationFolder() }
                    .accessibilityIdentifier("relocateSheet.chooseDest")
            }
            .padding(4)
            if let problem = destinationProblemText {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("relocateSheet.destinationProblem")
            }
            Toggle("Preserve source layout beneath the chosen folder (from_<Volume>/<subtree>)",
                   isOn: $preserveSourceLayout)
                .font(.caption)
                .padding(.horizontal, 4)
                .onChange(of: preserveSourceLayout) { _, _ in applyDestinationChoice() }
                .help("On: a chosen volume root becomes <root>/from_<SourceVolume>/<subtree>, so history stays readable in Finder. Off: files go exactly where you chose (the app tracks provenance either way).")
                .accessibilityIdentifier("relocateSheet.preserveLayout")
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
                    Text(previewResult == nil ? "Bytes to copy (upper bound):" : "Bytes to copy:")
                    Spacer()
                    Text(bytesToCopy.label)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("relocateSheet.bytesToCopy")
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
                        // Determinate narration (2026-07-06): the classify
                        // loop reports (done, total) — no more silent
                        // minutes behind a modal.
                        Text(previewProgress.map { "Comparing \($0.done) / \($0.total) files…" }
                             ?? "Enumerating volumes…")
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
            // GH #162 (2026-08-18): the Migrate wording breaks the scope
            // down by reconcile bucket once a preview exists ("3 to copy
            // (9.96 GB), 130 already at destination …") — the old
            // "134 record(s) (1.33 TB)" was the whole scope's bytes and
            // read as "1.33 TB will be copied". See
            // ReconcileLogLines.migrateButtonLabel for the fallback.
            let busy = model.isRelocating
            let label: String = {
                if dryRun {
                    return busy
                        ? "Add Dry Run to Queue (\(scopedRecords.count) record(s))"
                        : "Dry Run (\(scopedRecords.count) record(s))"
                }
                return ReconcileLogLines.migrateButtonLabel(scopeCount: scopedRecords.count,
                                                            scopeBytes: totalBytes,
                                                            plan: previewResult,
                                                            busy: busy)
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
        panel.message = "Choose the destination VOLUME (or folder). The app places files under from_<SourceVolume>/<subtree> so the history stays readable."
        panel.prompt = "Select"
        if let current = destinationFolder { panel.directoryURL = current }
        if panel.runModal() == .OK, let url = panel.url {
            chosenDestinationRoot = url
            applyDestinationChoice()
        }
    }

    /// Resolve the final destination from the user's choice + the layout
    /// toggle; show it before Migrate so nothing surprises.
    private func applyDestinationChoice() {
        guard let chosen = chosenDestinationRoot else { return }
        destinationFolder = preserveSourceLayout
            ? Self.derivedDestination(chosen: chosen, sourcePath: sourceVolumePath)
            : chosen.standardizedFileURL
        UserDefaults.standard.set(destinationFolder?.path, forKey: relocateDestFolderKey)
        invalidatePreview()  // dest change invalidates preview
    }

    /// Rick 2026-08-17: "humans easily make typos" — the app derives the
    /// destination folder from the choice, so the user only ever picks a
    /// volume. If the chosen folder is a VOLUME ROOT (or /Volumes/X),
    /// the destination becomes `<root>/from_<SourceVolume>/<subtree of the
    /// source beneath its volume>`; a source that IS a volume root maps to
    /// `<root>/from_<SourceVolume>`. Any deeper chosen folder is used as-is
    /// (the user meant it). Pure; tested.
    static func derivedDestination(chosen: URL, sourcePath: String) -> URL {
        let chosenStd = chosen.standardizedFileURL
        let comps = chosenStd.pathComponents            // ["/", "Volumes", "X", ...]
        let isVolumeRoot = comps.count == 3 && comps[1] == "Volumes"
        guard isVolumeRoot else { return chosenStd }
        let src = URL(fileURLWithPath: sourcePath).standardizedFileURL.pathComponents
        guard src.count >= 3, src[1] == "Volumes" else {
            // A non-/Volumes source (e.g. ~/Movies): from_<lastComponent>.
            let name = src.last ?? "source"
            return chosenStd.appendingPathComponent("from_\(name)", isDirectory: true)
        }
        var dest = chosenStd.appendingPathComponent("from_\(src[2])", isDirectory: true)
        for c in src.dropFirst(3) { dest.appendPathComponent(c, isDirectory: true) }
        return dest
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
        // Seam D — project the records the classify pass reads into Sendable
        // inputs HERE on the main actor (the enclosing Task inherits MainActor),
        // so no VideoRecord crosses into the detached task. `scope` stays on
        // main and is used to re-materialize the id-keyed plan afterwards.
        let scopeInputs = scope.map(\.asReconcileInput)
        let witnessInputs = model.records.map(\.asReconcileInput)
        let src = sourceVolumePath
        let skipDups = skipDupsOnOtherVolumes

        previewTask?.cancel()
        isPreviewing = true
        previewProgress = nil
        // Determinate progress from the classify loop, throttled to ≤4 Hz
        // on the main actor (2026-07-06 — Rick's honest-progress rule).
        let throttle = VideoScanModel.ReconcileProgressThrottle()
        let progressSink: @Sendable (Int, Int) -> Void = { done, total in
            let gates = throttle.gate()
            guard gates.ui || done == total else { return }
            Task { @MainActor in
                previewProgress = (done, total)
            }
        }
        previewTask = Task {
            let plan = await Task.detached(priority: .userInitiated) { () -> ReconcilePlan in
                let sourceFiles = Self.enumerateFiles(at: src)
                let destFiles = Self.enumerateFiles(at: dest.path)
                return RelocateReconcile.reconcilePlan(
                    records: scopeInputs,
                    witnesses: witnessInputs,
                    sourceVolumeRootPath: src,
                    destinationRoot: dest,
                    sourceFiles: sourceFiles,
                    destFiles: destFiles,
                    skipDupsOnOtherVolumes: skipDups,
                    // Must mirror handleRelocate()'s hardcoded value so the
                    // preview counts match what the run will actually do.
                    skipAlreadyRelocated: true,
                    hash: { FileHasher.partialMD5(path: $0) },
                    progress: progressSink
                )
            }.value
            if Task.isCancelled { return }   // superseded by a newer preview/invalidation
            let result = RelocateReconcile.materialize(plan, scope: scope)
            previewResult = result
            previewProgress = nil
            isPreviewing = false
            // GH #162 (2026-08-18): the preview's statements belong in
            // relocate.log too — summary + per-file buckets (esp. safely-
            // redundant + first witness), tagged [PREVIEW]. Logged HERE,
            // after the cancellation check, so a superseded preview never
            // leaves a misleading trail. Same string builder as the live run.
            model.logReconcilePreview(result,
                                      sourceVolumeRootPath: src,
                                      destinationRoot: dest)
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
        previewProgress = nil
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
