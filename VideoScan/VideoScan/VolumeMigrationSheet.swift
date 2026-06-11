import SwiftUI

// MARK: - VolumeMigrationSheet
//
// "Show Migrated…" on an offline/retired volume (Rick 2026-06-11):
// answers, in one glance, "is everything on this old disk safe
// somewhere else — and where?" Built from OnlineCopyFinder's
// MigrationReport (strict same-content identity, never the fuzzy
// duplicate scorer).
//
// The actionable tail is the gap: "Show N Unmigrated in Catalog"
// focuses the catalog table on exactly the records with no copy
// anywhere else, so a rescue pass can start from there.

/// Sheet payload — Identifiable for .sheet(item:).
struct VolumeMigrationItem: Identifiable {
    let id = UUID()
    /// Friendly label of the queried (offline/retired) volume.
    let volumeName: String
    let report: OnlineCopyFinder.MigrationReport
}

struct VolumeMigrationSheet: View {
    let item: VolumeMigrationItem
    /// "Show Unmigrated in Catalog" — parent dismisses and focuses the
    /// catalog on these record IDs.
    let onShowUnmigrated: ([UUID]) -> Void

    @Environment(\.dismiss) private var dismiss

    private var report: OnlineCopyFinder.MigrationReport { item.report }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Migration Status")
                    .font(.headline)
                Text(item.volumeName)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            headline

            if !report.destinations.isEmpty {
                destinationList
            }

            HStack {
                Spacer()
                if !report.unmigratedIDs.isEmpty {
                    Button("Show \(report.unmigratedIDs.count) Unmigrated in Catalog") {
                        onShowUnmigrated(report.unmigratedIDs)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("migration.showUnmigrated")
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.escape)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder
    private var headline: some View {
        if report.total == 0 {
            Label("No cataloged files on this volume.",
                  systemImage: "questionmark.circle")
                .foregroundColor(.secondary)
        } else if report.isFullyMigrated {
            VStack(alignment: .leading, spacing: 4) {
                Label("All \(report.total.formatted()) files have copies on other volumes.",
                      systemImage: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 13, weight: .semibold))
                usableNowLine
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label("\(report.unmigratedIDs.count.formatted()) of \(report.total.formatted()) files have no copy anywhere else.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 13, weight: .semibold))
                if report.migrated > 0 {
                    Text("\(report.migrated.formatted()) migrated.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    usableNowLine
                }
            }
        }
    }

    /// "Usable today" line — migrated is necessary, mounted is what
    /// lets Rick actually open the file this minute.
    @ViewBuilder
    private var usableNowLine: some View {
        if report.migratedOnlineNow < report.migrated {
            Text("\(report.migratedOnlineNow.formatted()) of the migrated copies are on volumes mounted right now.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        } else if report.migrated > 0 {
            Text("All migrated copies are on volumes mounted right now.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private var destinationList: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Copies Live On")
                    .font(.subheadline.weight(.semibold))
                ForEach(report.destinations, id: \.volumeLabel) { dest in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(dest.isOnline ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                            .help(dest.isOnline ? "Mounted now" : "Offline")
                        Text(dest.volumeLabel)
                            .font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Text("\(dest.recordCount.formatted()) file\(dest.recordCount == 1 ? "" : "s")")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        if !dest.isOnline {
                            Text("offline")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.gray.opacity(0.18)))
                        }
                    }
                }
            }
            .padding(4)
        }
    }
}
