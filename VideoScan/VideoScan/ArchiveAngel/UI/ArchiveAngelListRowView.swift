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
    /// An Archive Angel or Promote job is running (Prepare waits for it).
    var angelJobRunning = false
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
                if let where_ = row.location.text {
                    Text(where_)
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
            .help(promoteHelp)
            .disabled(!promoteEnabled)
            .opacity(promoteEnabled ? 1 : 0.45)
            .accessibilityIdentifier("archiveAngel.list.promote")
        ColorActionButton(title: "Archive Readiness", systemImage: "info.circle",
                          color: ColorActionButton.Palette.info, size: .large, action: onReadiness)
            .help("Why Archive Angel chose it, what it still needs, and what to do about it")
            .accessibilityIdentifier("archiveAngel.list.readiness")
    }

    private var promoteEnabled: Bool {
        row.promoteEnabled(readOnly: isReadOnly, angelJobRunning: angelJobRunning)
    }

    /// Says why the button is off, in the same words as the row.
    private var promoteHelp: String {
        if isReadOnly { return "This Mac is a read-only viewer of the catalog." }
        switch row.location {
        case .driveNotConnected: return "Connect the drive this file is on first."
        case .fileNotFound: return "The file is not where the catalog says — it may have been moved or deleted."
        case .available: break
        }
        if row.route == .prepare, angelJobRunning {
            return "Archive Angel is busy with another job — try again when it finishes (see the Media File Operations window)."
        }
        return row.route.help
    }
}
