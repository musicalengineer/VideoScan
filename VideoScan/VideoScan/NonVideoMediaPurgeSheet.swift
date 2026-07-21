import SwiftUI

// MARK: - Purge Non-Video Media dialog (2026-07-21)
//
// The single dialog that REPLACES the two separate purge sheets (cover-art
// music, unrelated audio). Two entry points, same view:
//   • Catalog ▸ "Purge Non-Video Media…"  (all volumes selected)
//   • right-click a volume in the Volumes window (that volume pre-selected,
//     others off) — via `preselectedVolumeKey`.
//
// Rick picks WHAT categories of non-video junk to purge and WHICH volumes,
// with live counts that update as he toggles, then purges — so he can clean
// volumes separately and explore before committing.
//
// EFFICIENT RECOMPUTE. The O(N) classification pass runs ONCE, in `.onAppear`,
// captured into @State (`classification`). Every number the body renders —
// per-category counts, per-volume counts, the grand total, the top-locations
// breakdown — is cheap cell arithmetic over that captured matrix
// (NonVideoMediaPurge.Classification), NOT another walk of the ~100k records.
// This keeps the no-O(records)-work-in-a-view-body rule: toggling a checkbox
// re-sums a handful of Ints, it never re-classifies the catalog.

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
    /// Currently-checked categories. Both on by default.
    @State private var selectedCategories: Set<NonVideoCategory> = Set(NonVideoCategory.allCases)
    /// Currently-checked volume keys. Filled on appear from the classification.
    @State private var selectedVolumeKeys: Set<String> = []

    private var total: Int {
        classification?.totalCount(categories: selectedCategories,
                                   volumeKeys: selectedVolumeKeys) ?? 0
    }

    private var purgeEnabled: Bool {
        guard classification != nil else { return false }
        // Local Int (not a collection `.count`) so SwiftLint empty_count
        // doesn't misfire on the `> 0` comparison.
        let n = total
        return !selectedCategories.isEmpty && !selectedVolumeKeys.isEmpty && n > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let classification {
                categorySection(classification)
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
                    model.purgeNonVideoMedia(categories: selectedCategories,
                                             volumeKeys: selectedVolumeKeys)
                    dismiss()
                }
                // Deliberately NOT the default action: this irreversibly
                // removes records, so a reflexive Enter must not trigger it.
                // Escape (Cancel) is the only keyboard path.
                .disabled(!purgeEnabled)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: computeOnAppear)
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

    @ViewBuilder
    private func categorySection(_ c: NonVideoMediaPurge.Classification) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What to purge")
                .font(.callout).bold()
            ForEach(NonVideoCategory.allCases) { cat in
                let n = c.categoryCount(cat, volumeKeys: selectedVolumeKeys)
                Toggle(isOn: categoryBinding(cat)) {
                    Text("\(cat.label) (\(n))")
                }
                .accessibilityIdentifier("nonVideoPurge.category.\(cat.rawValue)")
            }
            if selectedCategories.contains(.unrelatedAudio), !c.hasVideoAnchors {
                Label {
                    Text("Unrelated audio is unavailable — this catalog has no video records to relate audio to. Re-scan your video volumes first.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
                .font(.callout)
            }
            Text("Cover-art music: commercial purchases whose embedded art was mistaken for video. Unrelated audio: audio-only files with no link to any video (sample libraries, loops, standalone music). Audio that might belong to a video — same folder, matching name, shared Avid UMID, or an existing correlated pair — is KEPT.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                            let n = c.volumeCount(vk, categories: selectedCategories)
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
                let breakdown = c.topLocations(categories: selectedCategories,
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

    /// Set-membership Binding for a category checkbox. (SwiftUI `Binding` ≈ a
    /// get/set pair the control reads and writes — here it toggles set
    /// membership rather than a stored Bool.)
    private func categoryBinding(_ cat: NonVideoCategory) -> Binding<Bool> {
        Binding(
            get: { selectedCategories.contains(cat) },
            set: { on in
                if on { selectedCategories.insert(cat) }
                else { selectedCategories.remove(cat) }
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
        // Default selections: all categories; volumes depend on the entry
        // point. A NON-NIL preselection (volume right-click) must NEVER fall
        // through to "all volumes" — that would silently arm the whole catalog
        // from a "clean this one drive" gesture. A right-clicked volume with no
        // candidates opens to an empty, Purge-disabled dialog (correct). Only
        // the nil case (Catalog-menu entry) selects every volume with junk.
        selectedCategories = Set(NonVideoCategory.allCases)
        if let key = preselectedVolumeKey {
            selectedVolumeKeys = c.volumeKeys.contains(key) ? [key] : []
        } else {
            selectedVolumeKeys = Set(c.volumeKeys)
        }
    }
}
