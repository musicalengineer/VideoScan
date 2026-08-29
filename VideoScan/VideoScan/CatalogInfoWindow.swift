// CatalogInfoWindow.swift
// Catalog Info window (payload + content) and the catalog sync banner.
// Extracted verbatim from ContentView.swift (refactor 2026-06-11) —
// behavior-preserving move, no rewrites.

import SwiftUI

/// Payload for the Catalog Info window. Codable/Hashable so it can back a
/// `WindowGroup(for:)` scene — SwiftUI uses the value for window identity
/// and session restoration, so two different volumes produce two distinct
/// windows.
struct CatalogInfoItem: Identifiable, Codable, Hashable {
    /// Stable id — using the volume path means re-invoking Catalog Info on
    /// the same volume focuses the existing window instead of stacking
    /// duplicates. A fresh UUID would open a new window every click.
    var id: String { volumePath }
    let volumePath: String
    let title: String
    let message: String
}

/// Contents of the Catalog Info window. Independent resizable AppKit window
/// (not a sheet) so Rick can drag edges freely, keep it open while working,
/// or compare two volumes side by side.
struct CatalogInfoWindow: View {
    let item: CatalogInfoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.title)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                Text(item.message)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }

            Divider()

            HStack {
                Spacer()
                Button("Copy") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(item.message, forType: .string)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

// MARK: - Catalog Sync Banner
//
// Two visual states for the viewer (read-only) Macs:
//
//   * Synced — subtle gray strip: the master is reachable, the catalog
//     was rsync'd in successfully, manifest verified. Quiet so it
//     doesn't compete with the rest of the UI.
//
//   * Fallback (master offline / sync failed) — amber strip with an
//     attention icon. Worded so the user can NEVER mistake stale data
//     for live data: "MASTER OFFLINE — showing snapshot from <ago>".
//
// On the master itself this view isn't rendered at all (see ContentView).

struct CatalogSyncBanner: View {
    @ObservedObject var sync: CatalogSync
    /// Phase 1 remote use: the chip's "media: streaming / master offline"
    /// word, refreshed by a ping on appear and every minute.
    @ObservedObject private var media = ViewerMediaStatus.shared

    var body: some View {
        HStack(spacing: 10) {
            iconView
            VStack(alignment: .leading, spacing: 1) {
                Text(headlineText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(headlineColor)
                if let sub = subText {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(headlineColor.opacity(0.85))
                }
            }
            Spacer()
            Button(action: { Task { await sync.syncFromMaster() } }) {
                if case .syncing = sync.state.phase {
                    ProgressView().controlSize(.small)
                } else {
                    Text(isFallback ? "Retry" : "Refresh")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled({ if case .syncing = sync.state.phase { return true } else { return false } }())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .accessibilityIdentifier("viewer.statusChip")
        .task {
            // Ping the master's web server for the media word; 4 s cap,
            // once a minute — never on the render path.
            let configuration = MediaStreamResolver.Configuration.fromDefaults(masterHostname: sync.masterHostname)
            while !Task.isCancelled {
                _ = await ViewerMediaStatus.shared.refresh(configuration: configuration)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    // MARK: - Visual state

    private var isFallback: Bool {
        switch sync.state.phase {
        case .failed, .idle: return true
        case .syncing, .synced: return false
        }
    }

    private var backgroundColor: Color {
        isFallback
            ? Color(red: 0.85, green: 0.45, blue: 0.10)   // amber — can't-miss
            : Color(NSColor.controlBackgroundColor)
    }

    private var headlineColor: Color {
        isFallback ? .white : .secondary
    }

    private var iconView: some View {
        Image(systemName: isFallback ? "exclamationmark.triangle.fill" : "checkmark.circle")
            .foregroundStyle(headlineColor)
            .font(.system(size: 14, weight: .semibold))
    }

    private var headlineText: String {
        switch sync.state.phase {
        case .idle:
            if let last = sync.state.lastSuccessfulSync {
                return "MASTER OFFLINE — showing snapshot from \(relative(last))"
            }
            return "MASTER OFFLINE — no previous snapshot available"
        case .syncing:
            return ViewerStatusChipText.compose(
                masterDisplayName: ViewerModeCenter.shortName(sync.masterHostname),
                syncedAt: sync.state.lastSuccessfulSync, syncing: true, media: media.label)
        case .synced(let at):
            return ViewerStatusChipText.compose(
                masterDisplayName: ViewerModeCenter.shortName(sync.masterHostname),
                syncedAt: at, syncing: false, media: media.label)
        case .failed:
            if let last = sync.state.lastSuccessfulSync {
                return "MASTER OFFLINE — showing snapshot from \(relative(last))"
            }
            return "MASTER OFFLINE — no previous snapshot available"
        }
    }

    private var subText: String? {
        switch sync.state.phase {
        case .failed(let reason): return reason
        default: return nil
        }
    }

    private func relative(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}
