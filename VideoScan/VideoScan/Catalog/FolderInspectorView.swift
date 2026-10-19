// FolderInspectorView.swift
// The inspector for a selected folder (Rick 2026-10-19: "never empty"),
// and the file inspector's "In folders: Dad, Thanksgiving 1990" line.
//
// FolderInspectorView reads ONE value (FolderInspectorFacts, computed in
// the selection handler); InspectorFoldersLine observes the folder store
// (its own small view, like MakeFolderBannerButton) so a membership change
// re-draws the line and nothing else. Neither does O(records) work: the
// line is one O(1) lookup in the store's folded snapshot.
//
// (For Rick: two leaf widgets; `@ObservedObject` ≈ subscribing this one
// widget to the store's change signal.)

import SwiftUI

struct FolderInspectorView: View {
    let facts: FolderInspectorFacts

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: FootageFolderWords.folderSymbol)
                        .font(.system(size: 26))
                        .foregroundColor(FootageFolderWords.folderTint(for: facts.kind))
                    Text(facts.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                .padding(.bottom, 4)
                Divider()
                row(FootageFolderWords.inspectorKind, facts.kind.title)
                row(FootageFolderWords.inspectorFiles, facts.filesWords)
                row(FootageFolderWords.inspectorDuration, facts.totalSeconds > 0 ? RelatedLadder.mmss(facts.totalSeconds) : "—")
                row(FootageFolderWords.inspectorSize, facts.totalBytes > 0 ? MediaBytes.display(facts.totalBytes) : "—")
                row(FootageFolderWords.inspectorDates, facts.dateRangeWords)
                row(FootageFolderWords.inspectorVolumes, facts.volumesWords)
                row(FootageFolderWords.inspectorOnline, facts.onlineWords)
                Divider()
                row(FootageFolderWords.inspectorCreated, FolderInspectorFacts.stampFormatter.string(from: facts.createdAt))
                row(FootageFolderWords.inspectorChanged, FolderInspectorFacts.stampFormatter.string(from: facts.updatedAt))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .accessibilityIdentifier("catalog.folderInspector")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(width: 104, alignment: .trailing)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "In folders: Dad, Thanksgiving 1990" under a file's header; nothing when
/// the file is in no folder.
struct InspectorFoldersLine: View {
    /// nil = the file cannot be in a folder (no content identity).
    let contentKey: String?
    @ObservedObject private var store = EventsDecisionStore.shared

    var body: some View {
        let names = contentKey.map(store.folderNames(containing:)) ?? []
        if !names.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: FootageFolderWords.folderSymbol)
                    .foregroundColor(FootageFolderWords.folderTint)
                Text("\(FootageFolderWords.inFolders): \(names.joined(separator: ", "))")
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .accessibilityIdentifier("catalog.inspector.inFolders")
        }
    }
}
