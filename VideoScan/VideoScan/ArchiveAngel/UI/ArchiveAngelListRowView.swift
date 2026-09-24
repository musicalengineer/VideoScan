// ArchiveAngelListRowView.swift
// One row of the Archive Angel recommendations list, drawn for senior eyes
// (Rick 2026-09-24): the filename large, plain status words instead of a
// letter grade, and five coloured, labelled buttons in Hallie's style
// (ColorActionButton, .large): Play · Show in Catalog · Show in Finder ·
// Promote/Prepare to Archive · Archive Readiness. No score on the row.
//
// Pure presentation: the row model is precomputed (ArchiveAngelListRow);
// the buttons call closures. When the pane is too narrow for five buttons
// in a line they wrap to two lines (ViewThatFits) rather than shrink.

import SwiftUI

struct ArchiveAngelListRowView: View {
    let row: ArchiveAngelListRow
    let isReadOnly: Bool
    let onPlay: () -> Void
    let onShowInCatalog: () -> Void
    let onShowInFinder: () -> Void
    let onPromote: () -> Void
    let onReadiness: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.filename)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(row.path)
                statusChip
                if !row.isReachable {
                    Text("drive not connected")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { firstButtons; secondButtons }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) { firstButtons }
                    HStack(spacing: 12) { secondButtons }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.filename), \(row.statusWords)")
    }

    private var statusColor: Color {
        if row.isReady { return ColorActionButton.Palette.archive }
        return row.needs.isEmpty ? .secondary : .orange
    }

    private var statusChip: some View {
        HStack(spacing: 6) {
            Image(systemName: row.isReady ? "checkmark.seal.fill" : "exclamationmark.circle")
            Text(row.statusWords)
        }
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(statusColor)
        .fixedSize()
        .accessibilityIdentifier("archiveAngel.list.status")
    }

    @ViewBuilder
    private var firstButtons: some View {
        ColorActionButton(title: "Play", systemImage: "play.fill",
                          color: ColorActionButton.Palette.play, size: .large, action: onPlay)
            .help("Play it — QuickTime when it can, VLC for what QuickTime can't open.")
            .accessibilityIdentifier("archiveAngel.list.play")
        ColorActionButton(title: "Show in Catalog", systemImage: "film.stack",
                          color: ColorActionButton.Palette.showInCatalog, size: .large, action: onShowInCatalog)
            .help("Show it in the Catalog — the row, its preview and details")
            .accessibilityIdentifier("archiveAngel.list.showInCatalog")
        ColorActionButton(title: "Show in Finder", systemImage: "folder",
                          color: ColorActionButton.Palette.showInFinder, size: .large, action: onShowInFinder)
            .help("Show the file in Finder")
            .accessibilityIdentifier("archiveAngel.list.showInFinder")
    }

    @ViewBuilder
    private var secondButtons: some View {
        ColorActionButton(title: row.route.buttonTitle,
                          systemImage: row.route == .direct ? "archivebox.fill" : "wand.and.stars",
                          color: ColorActionButton.Palette.archive, size: .large, action: onPromote)
            .help(isReadOnly ? "This Mac is a read-only viewer of the catalog." : row.route.help)
            .disabled(isReadOnly || !promoteAvailable)
            .opacity(isReadOnly || !promoteAvailable ? 0.45 : 1)
            .accessibilityIdentifier("archiveAngel.list.promote")
        ColorActionButton(title: "Archive Readiness", systemImage: "info.circle",
                          color: ColorActionButton.Palette.info, size: .large, action: onReadiness)
            .help("Why Archive Angel chose it, what it still needs, and what to do about it")
            .accessibilityIdentifier("archiveAngel.list.readiness")
    }

    private var promoteAvailable: Bool {
        if case .unavailable = row.route { return false }
        return true
    }
}
