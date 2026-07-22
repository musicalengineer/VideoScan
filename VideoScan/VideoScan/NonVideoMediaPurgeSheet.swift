import SwiftUI

// MARK: - Purge Non-Video Media dialog (2026-07-21)
//
// The single dialog that lets Rick clean non-video junk out of the catalog.
// REDESIGN (Rick, 2026-07-21): the "What to purge" control is a PURE EXTENSION
// CHECKLIST — one row per file EXTENSION present in the catalog (excluding
// video containers / Avid essence), each with a human label, a live count for
// the selected volumes, and a "(N paired)" annotation (orange) when any of
// those records belong to an A/V pair. Nothing is checked by default: opening
// the dialog purges nothing until the user explicitly checks extensions. Two
// entry points, same view:
//   • Catalog ▸ "Purge Non-Video Media…"  (all volumes selected)
//   • right-click a volume in the Volumes window (that volume pre-selected,
//     others off) — via `preselectedVolumeKey`.
//
// EFFICIENT RECOMPUTE. The O(N) classification pass runs ONCE, in `.onAppear`,
// captured into @State (`classification`). Every number the body renders —
// per-extension counts + paired counts, per-volume counts, the grand total,
// the top-locations breakdown — is cheap cell arithmetic over that captured
// matrix (NonVideoMediaPurge.Classification), NOT another walk of the ~100k
// records. This keeps the no-O(records)-work-in-a-view-body rule: toggling a
// checkbox re-sums a handful of Ints, it never re-classifies the catalog.

struct NonVideoMediaPurgeSheet: View {
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss

    /// When non-nil, open with ONLY this volume selected (the volume
    /// right-click entry point). nil = the Catalog-menu entry point → all
    /// volumes selected.
    let preselectedVolumeKey: String?

    init(preselectedVolumeKey: String? = nil) {
        self.preselectedVolumeKey = preselectedVolumeKey
    }

    /// The one-shot classification, filled on appear. nil = not yet computed.
    @State private var classification: NonVideoMediaPurge.Classification? = nil
    /// Currently-checked extensions. EMPTY by default — explicit opt-in.
    @State private var selectedExtensions: Set<String> = []
    /// Currently-checked volume keys. Filled on appear from the classification.
    @State private var selectedVolumeKeys: Set<String> = []
    /// Non-nil once Purge has run: the sheet swaps its selection UI for the
    /// completion confirmation (count removed + recovery snapshot path). This is
    /// an in-sheet STATE SWAP rather than a second modal — simpler here and
    /// keeps the one-window flow. (SwiftUI @State ≈ a member that, when it
    /// changes, re-invokes body — like a value that redraws on assignment.)
    @State private var outcome: PurgeOutcome? = nil

    private var total: Int {
        classification?.totalCount(extensions: selectedExtensions,
                                   volumeKeys: selectedVolumeKeys) ?? 0
    }

    private var purgeEnabled: Bool {
        guard classification != nil else { return false }
        // Local Int (not a collection `.count`) so SwiftLint empty_count
        // doesn't misfire on the `> 0` comparison.
        let n = total
        return !selectedExtensions.isEmpty && !selectedVolumeKeys.isEmpty && n > 0
    }

    var body: some View {
        Group {
            if let outcome {
                completionView(outcome)
            } else {
                selectionView
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: computeOnAppear)
    }

    /// The pre-purge selection UI (extensions, volumes, summary, Purge button).
    private var selectionView: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let classification {
                extensionSection(classification)
                Divider()
                volumeSection(classification)
                Divider()
                summarySection(classification)
                safetyNote
            } else {
                ProgressView().controlSize(.small)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Purge", role: .destructive) {
                    // Do NOT dismiss — swap to the completion state so the user
                    // gets an explicit "it's done" with the count and the
                    // recovery-snapshot path.
                    outcome = model.purgeNonVideoMedia(extensions: selectedExtensions,
                                                       volumeKeys: selectedVolumeKeys)
                }
                // Deliberately NOT the default action: this irreversibly
                // removes records, so a reflexive Enter must not trigger it.
                // Escape (Cancel) is the only keyboard path.
                .disabled(!purgeEnabled)
            }
        }
    }

    /// Post-purge confirmation. Shows a clear "done" signal, the count removed,
    /// and — because the operation is destructive — where the recovery snapshot
    /// was written. A single OK button dismisses.
    @ViewBuilder
    private func completionView(_ outcome: PurgeOutcome) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: outcome.removed > 0
                      ? "checkmark.circle.fill" : "info.circle")
                    .font(.system(size: 22))
                    .foregroundColor(outcome.removed > 0 ? .green : .secondary)
                Text("Purge complete.")
                    .font(.title3).bold()
            }

            if outcome.removed > 0 {
                Text("Removed \(outcome.removed) record\(outcome.removed == 1 ? "" : "s") from the catalog.")
                    .font(.callout).bold()
                    .fixedSize(horizontal: false, vertical: true)

                if let path = outcome.snapshotPath {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recovery snapshot saved to:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                        Text("Files on disk were not touched.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)
                } else {
                    Text("Files on disk were not touched.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                // N == 0: nothing in the catalog matched the selected extensions
                // and volumes. Say so plainly.
                Text("Nothing to remove.")
                    .font(.callout).bold()
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing in the catalog matched the selected extensions and volumes, so no records were removed and no snapshot was written.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash.slash")
                .font(.system(size: 22))
                .foregroundColor(.accentColor)
            Text("Purge Non-Video Media")
                .font(.title3).bold()
        }
    }

    /// The extension checklist: one row per offered extension, biggest-count
    /// first, each with a human label, a live count for the selected volumes,
    /// and an orange "(N paired)" annotation when any of those records belong
    /// to an A/V pair — the visible guard against unknowingly severing a pair.
    @ViewBuilder
    private func extensionSection(_ c: NonVideoMediaPurge.Classification) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("What to purge")
                    .font(.callout).bold()
                Spacer()
                Button("All") { selectedExtensions = Set(c.extensions) }
                    .buttonStyle(.link)
                    .disabled(selectedExtensions.count == c.extensions.count)
                Button("None") { selectedExtensions = [] }
                    .buttonStyle(.link)
                    .disabled(selectedExtensions.isEmpty)
            }
            if c.extensions.isEmpty {
                Text("No purgeable non-video media in the catalog. (Video files and Avid essence are never listed here.)")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(c.extensions, id: \.self) { ext in
                            extensionRow(c, ext)
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: 200)
                Text("Choose the file types to remove from the catalog. Only non-video types are listed — video files and Avid essence are never offered here. \"(N paired)\" means N of those records belong to an audio/video pair; removing them severs that pairing in the catalog.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func extensionRow(_ c: NonVideoMediaPurge.Classification, _ ext: String) -> some View {
        let n = c.extensionCount(ext, volumeKeys: selectedVolumeKeys)
        let paired = c.extensionPairedCount(ext, volumeKeys: selectedVolumeKeys)
        Toggle(isOn: extensionBinding(ext)) {
            HStack(spacing: 6) {
                Text(".\(ext)")
                    .font(.system(.callout, design: .monospaced))
                Text(NonVideoMediaPurge.label(forExtension: ext))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if paired > 0 {
                    Text("(\(paired) paired)")
                        .font(.callout)
                        .foregroundColor(.orange)
                }
                Text("\(n)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .accessibilityIdentifier("nonVideoPurge.ext.\(ext)")
    }

    @ViewBuilder
    private func volumeSection(_ c: NonVideoMediaPurge.Classification) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Which volumes")
                    .font(.callout).bold()
                Spacer()
                Button("All") { selectedVolumeKeys = Set(c.volumeKeys) }
                    .buttonStyle(.link)
                    .disabled(selectedVolumeKeys.count == c.volumeKeys.count)
                Button("None") { selectedVolumeKeys = [] }
                    .buttonStyle(.link)
                    .disabled(selectedVolumeKeys.isEmpty)
            }
            if c.volumeKeys.isEmpty {
                Text("No purgeable non-video records in the catalog.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(c.volumeKeys, id: \.self) { vk in
                            let n = c.volumeCount(vk, extensions: selectedExtensions)
                            Toggle(isOn: volumeBinding(vk)) {
                                HStack {
                                    Text(vk.isEmpty ? "(unknown volume)" : vk)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Text("\(n)")
                                        .font(.system(.callout, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .accessibilityIdentifier("nonVideoPurge.volume.\(vk)")
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: 160)
            }
        }
    }

    @ViewBuilder
    private func summarySection(_ c: NonVideoMediaPurge.Classification) -> some View {
        let n = total
        VStack(alignment: .leading, spacing: 6) {
            Text(n == 0
                 ? "Nothing selected to remove."
                 : "Remove \(n) record\(n == 1 ? "" : "s") from the catalog? Files on disk are untouched.")
                .font(.callout).bold()
                .fixedSize(horizontal: false, vertical: true)
            if n > 0 {
                let breakdown = c.topLocations(extensions: selectedExtensions,
                                               volumeKeys: selectedVolumeKeys)
                treesBreakdown(breakdown.trees, total: breakdown.total)
            }
        }
    }

    private var safetyNote: some View {
        Text("A recovery snapshot is saved first (its path is logged to the console). There is no in-app Undo — to restore, quit and copy that snapshot back over catalog.json (or simply re-scan the volume).")
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The "what will be removed" breakdown: the top parent directories among
    /// the selected candidates, with counts. Recomputed cheaply from the
    /// captured classification whenever selections change.
    @ViewBuilder
    private func treesBreakdown(_ trees: [NonVideoMediaPurge.TreeCount], total: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Top locations to be removed:")
                .font(.callout).bold()
            ForEach(trees) { tree in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(tree.count)")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(minWidth: 60, alignment: .trailing)
                    Text(tree.path.isEmpty ? "(no path)" : tree.path)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(tree.path)
                }
            }
            let shown = trees.reduce(0) { $0 + $1.count }
            if shown < total {
                Text("…and \(total - shown) more in other locations.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
    }

    // MARK: - Bindings & lifecycle

    /// Set-membership Binding for an extension checkbox. (SwiftUI `Binding` ≈ a
    /// get/set pair the control reads and writes — here it toggles set
    /// membership rather than a stored Bool.)
    private func extensionBinding(_ ext: String) -> Binding<Bool> {
        Binding(
            get: { selectedExtensions.contains(ext) },
            set: { on in
                if on { selectedExtensions.insert(ext) }
                else { selectedExtensions.remove(ext) }
            }
        )
    }

    private func volumeBinding(_ vk: String) -> Binding<Bool> {
        Binding(
            get: { selectedVolumeKeys.contains(vk) },
            set: { on in
                if on { selectedVolumeKeys.insert(vk) }
                else { selectedVolumeKeys.remove(vk) }
            }
        )
    }

    private func computeOnAppear() {
        // The one O(N) pass — off the view body, captured into @State.
        let c = model.classifyNonVideoMedia()
        classification = c
        // Default selections: NO extensions (explicit opt-in — opening the
        // dialog purges nothing until the user checks a type). Volumes depend
        // on the entry point. A NON-NIL preselection (volume right-click) must
        // NEVER fall through to "all volumes" — that would silently arm the
        // whole catalog from a "clean this one drive" gesture. A right-clicked
        // volume with no candidates opens to an empty, Purge-disabled dialog
        // (correct). Only the nil case (Catalog-menu entry) selects every
        // volume with junk.
        selectedExtensions = []
        if let key = preselectedVolumeKey {
            selectedVolumeKeys = c.volumeKeys.contains(key) ? [key] : []
        } else {
            selectedVolumeKeys = Set(c.volumeKeys)
        }
    }
}
