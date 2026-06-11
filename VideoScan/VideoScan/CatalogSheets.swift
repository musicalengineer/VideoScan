// CatalogSheets.swift
// Catalog tab sheets and menus: rename sheet, notes sheet, discover-volumes
// sheet, scan-options menu. Extracted verbatim from CatalogHelpers.swift
// (refactor 2026-06-11) — behavior-preserving move, no rewrites.

import SwiftUI

// MARK: - Rename Sheet

struct RenameSheet: View {
    @Binding var filename: String
    let originalExt: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename File")
                .font(.headline)
            HStack {
                TextField("New name", text: $filename)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text(".\(originalExt)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(filename.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

// MARK: - Notes Sheet

struct NotesSheet: View {
    @Binding var notes: String
    let filename: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notes")
                .font(.headline)
            Text(filename)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
            TextEditor(text: $notes)
                .font(.system(.body))
                .frame(minHeight: 80)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 220)
    }
}

// MARK: - Discover Volumes Sheet

struct DiscoverVolumesSheet: View {
    @ObservedObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    @State private var volumes: [DiscoveredVolume] = []
    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "network")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Discover Volumes")
                        .font(.headline)
                    Text("Mounted local and network volumes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            if volumes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No volumes found")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Mount a drive or network share and click Refresh.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(volumes, selection: $selected) { vol in
                    HStack(spacing: 10) {
                        Image(systemName: vol.isNetwork ? "network" : "internaldrive")
                            .font(.title3)
                            .foregroundColor(vol.isNetwork ? .blue : .secondary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(vol.name)
                                    .font(.system(size: 13, weight: .semibold))
                                if vol.isNetwork {
                                    Text("Network")
                                        .font(.system(size: 9, weight: .medium))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.blue.opacity(0.15))
                                        .cornerRadius(3)
                                        .foregroundColor(.blue)
                                }
                                if vol.alreadyAdded {
                                    Text("Already added")
                                        .font(.system(size: 9, weight: .medium))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.green.opacity(0.15))
                                        .cornerRadius(3)
                                        .foregroundColor(.green)
                                }
                            }
                            Text(vol.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            if vol.totalBytes > 0 {
                                Text("\(vol.usedFormatted) used of \(vol.totalFormatted)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .tag(vol.id)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            Divider()

            // Footer
            HStack {
                Text("\(volumes.count) volume(s) found")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Selected (\(selected.count))") {
                    let toAdd = volumes.filter { selected.contains($0.id) && !$0.alreadyAdded }
                    model.addDiscoveredVolumes(toAdd)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 550, height: 420)
        .onAppear { refresh() }
    }

    private func refresh() {
        volumes = model.discoverVolumes()
        selected = []
    }
}

// MARK: - Scan Options Menu

/// Toolbar menu for toggling what the walker descends into and two perf
/// shortcuts. All toggles are applied at scan start (not mid-scan), so the
/// next "Scan All" reflects the new policy. Defaults = aggressive skip
/// (only descend where family media plausibly lives).
struct ScanOptionsMenu: View {
    @ObservedObject var model: VideoScanModel

    /// Binding wrapper that saves to UserDefaults on every toggle, so the
    /// user's preference survives relaunch without an explicit "Save" step.
    private func toggle(_ keyPath: WritableKeyPath<ScanOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.scanOptions[keyPath: keyPath] },
            set: { newVal in
                model.scanOptions[keyPath: keyPath] = newVal
                model.scanOptions.save()
            }
        )
    }

    var body: some View {
        Menu {
            Toggle("Skip System Files", isOn: toggle(\.skipSystemFiles))
            Toggle("Skip Media Bundles", isOn: toggle(\.skipMediaBundles))
            Toggle("Skip Small Files", isOn: toggle(\.skipSmallFiles))
            Toggle("Skip Checksums", isOn: toggle(\.skipChecksums))

            Divider()

            Button("Fast Defaults") {
                model.scanOptions = .fastDefaults
                model.scanOptions.save()
            }
            .disabled(model.scanOptions == .fastDefaults)

            Button("Scan Everything (Slower)") {
                model.scanOptions = .thorough
                model.scanOptions.save()
            }
            .disabled(model.scanOptions == .thorough)
        } label: {
            HStack(spacing: 4) {
                Label("Scan Options", systemImage: "slider.horizontal.3")
                // Accent-colored dot when the user has deviated from the
                // fast-path defaults — visible at a glance.
                if model.scanOptions.isCustomized {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(model.scanOptions.isCustomized
              ? "Non-default scan policy (applies on next scan)"
              : "What to skip during scan (applies on next scan)")
    }
}

