import SwiftUI

// MARK: - InspectorWorkflowTagsView
//
// "Tags" section of the catalog Inspector (workflow tags,
// 2026-07-23). A chip row — tag name + × to remove — plus a small ⊕
// menu offering the WorkflowTags quick-picks and a free-form custom
// entry. Sibling to InspectorFamilyTagsView (people tags) but simpler:
// workflow tags have no tiers, no edit-mode gate — the × is small and
// deliberate enough that browsing clicks are safe.
//
// All mutations route through VideoScanModel's tag helpers so the
// search index refreshes and the debounced save fires on every change
// (same pipeline as the context menu's Tags submenu — one mutation
// path, zero drift).

struct InspectorWorkflowTagsView: View {

    let record: VideoRecord
    @EnvironmentObject var model: VideoScanModel

    /// Inline custom-tag entry, revealed by the ⊕ menu's "Custom
    /// Tag…" item. Lives here (not an alert) so the inspector flow
    /// stays in-panel.
    @State private var showCustomField = false
    @State private var customText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Chip row. Wrapped as a VStack of single-line HStacks like
            // InspectorFamilyTagsView's tagRow — a real flow layout is
            // heavier than a few chips deserve.
            if record.tags.isEmpty {
                Text("No tags yet")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(record.tags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.teal)
                            Button {
                                model.removeTag(tag, from: record)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.teal.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .help("Remove the \u{201C}\(tag)\u{201D} tag")
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.teal.opacity(0.12))
                        )
                    }
                }
            }

            // ⊕ add menu — quick-picks not yet on the record, plus the
            // custom entry.
            HStack(spacing: 6) {
                Menu {
                    ForEach(WorkflowTags.quickPicks, id: \.self) { tag in
                        let present = WorkflowTags.contains(record.tags, tag)
                        Button {
                            model.setTag(tag, on: [record], present: true)
                        } label: {
                            if present {
                                Label(tag, systemImage: "checkmark")
                            } else {
                                Text(tag)
                            }
                        }
                        .disabled(present)
                    }
                    Divider()
                    Button("Custom Tag\u{2026}") {
                        customText = ""
                        showCustomField = true
                    }
                } label: {
                    Label("Add Tag", systemImage: "plus.circle")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .fixedSize()
            }

            if showCustomField {
                HStack(spacing: 4) {
                    TextField("Your tag", text: $customText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11))
                        .onSubmit { commitCustomTag() }
                    Button("Add") { commitCustomTag() }
                        .controlSize(.small)
                        .disabled(customText.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button {
                        showCustomField = false
                        customText = ""
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func commitCustomTag() {
        model.addTag(customText, to: [record])
        customText = ""
        showCustomField = false
    }
}
