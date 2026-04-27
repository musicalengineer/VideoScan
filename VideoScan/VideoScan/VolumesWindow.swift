//
//  VolumesWindow.swift
//  VideoScan
//
//  Full editor for volume metadata: role, trust, media tech, filesystem,
//  purchase year, capacity, notes. Reachable via Window menu (⌘⇧V) or by
//  clicking a VolumeBadge anywhere in the app. Shows the computed
//  destination policy so you see at a glance what's archive-safe.
//

import SwiftUI

struct VolumesWindow: View {
    @EnvironmentObject var model: VideoScanModel
    @State private var selectedID: UUID?
    @State private var sidebarWidth: CGFloat = 320

    /// Sidebar font/badge scale — grows from 1.0 at 320pt to 1.5 at 540pt.
    /// The text and badge metrics in `VolumeListRow` multiply by this so a wider
    /// sidebar gets proportionally bigger labels (Rick's stretch goal).
    private var sidebarScale: CGFloat {
        let base: CGFloat = 320
        let max: CGFloat = 540
        let raw = (sidebarWidth - base) / (max - base)
        return 1.0 + (Swift.max(0, Swift.min(1, raw)) * 0.5)
    }

    /// Hide the RAM disk scratch volume (VideoScan_Temp) — it's plumbing,
    /// not an archive target, and shouldn't show up in the Volumes editor.
    private var sortedTargets: [CatalogScanTarget] {
        model.scanTargets
            .filter { !$0.searchPath.contains("VideoScan_Temp") }
            .sorted {
                VolumeReachability.volumeName(forPath: $0.searchPath)
                    .localizedCaseInsensitiveCompare(
                        VolumeReachability.volumeName(forPath: $1.searchPath)
                    ) == .orderedAscending
            }
    }

    private var selectedTarget: CatalogScanTarget? {
        if let id = selectedID,
           let t = sortedTargets.first(where: { $0.id == id }) {
            return t
        }
        return sortedTargets.first
    }

    var body: some View {
        HSplitView {
            volumeList
                .frame(minWidth: 280, idealWidth: 360, maxWidth: 600)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: SidebarWidthKey.self, value: geo.size.width)
                    }
                )
                .onPreferenceChange(SidebarWidthKey.self) { sidebarWidth = $0 }
            if let target = selectedTarget {
                VolumeEditor(target: target)
                    .id(target.id)
                    .frame(minWidth: 460)
            } else {
                placeholder
                    .frame(minWidth: 460)
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .onAppear { honorPendingSelection() }
        .onChange(of: model.pendingVolumesSelectionID) { honorPendingSelection() }
    }

    private func honorPendingSelection() {
        if let pending = model.pendingVolumesSelectionID {
            selectedID = pending
            model.pendingVolumesSelectionID = nil
        }
    }

    private var volumeList: some View {
        List(selection: $selectedID) {
            Section("Volumes") {
                ForEach(sortedTargets) { target in
                    VolumeListRow(target: target, scale: sidebarScale)
                        .tag(Optional(target.id))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No volumes")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("Add a volume from the Catalog tab to manage its metadata here.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar Row

private struct VolumeListRow: View {
    @ObservedObject var target: CatalogScanTarget
    var scale: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 8) {
            VolumeBadge(role: target.role,
                        trust: target.trust,
                        isReachable: target.isReachable)
                .scaleEffect(scale, anchor: .leading)
                .frame(width: 38 * scale, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(VolumeReachability.volumeName(forPath: target.searchPath))
                    .font(.system(size: 14 * scale, weight: .medium))
                    .lineLimit(1)
                Text(target.searchPath)
                    .font(.system(size: 11 * scale, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            PolicyBadge(policy: target.destinationPolicy)
                .scaleEffect(0.95 * scale, anchor: .trailing)
        }
        .padding(.vertical, 3)
    }
}

private struct SidebarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 320
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Editor

private struct VolumeEditor: View {
    @EnvironmentObject var model: VideoScanModel
    @ObservedObject var target: CatalogScanTarget

    @State private var purchaseYearText: String = ""
    @State private var capacityTBText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                workflowSection
                Divider()
                hardwareSection
                Divider()
                notesSection
                Spacer(minLength: 8)
            }
            .padding(20)
        }
        .onAppear { syncTextFields() }
        .onChange(of: target.id) { syncTextFields() }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: target.role.icon)
                    .font(.system(size: 32))
                    .foregroundColor(target.role.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(VolumeReachability.volumeName(forPath: target.searchPath))
                        .font(.title.bold())
                    Text(target.searchPath)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                PolicyBadge(policy: target.destinationPolicy)
                    .scaleEffect(1.15)
            }
            HStack(spacing: 6) {
                Image(systemName: target.isReachable ? "checkmark.circle.fill" : "wifi.slash")
                    .foregroundColor(target.isReachable ? .green : .orange)
                Text(target.isReachable ? "Online" : "Offline")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var workflowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Workflow").font(.title3.bold())
            HStack(alignment: .top, spacing: 24) {
                pickerColumn(title: "Role") {
                    Picker("", selection: Binding(
                        get: { target.role },
                        set: { model.setRole($0, for: target) }
                    )) {
                        ForEach(VolumeRole.allCases, id: \.self) { r in
                            Label(r.rawValue, systemImage: r.icon).tag(r)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                pickerColumn(title: "Reliability") {
                    Picker("", selection: Binding(
                        get: { target.trust },
                        set: { model.setTrust($0, for: target) }
                    )) {
                        ForEach(VolumeTrust.allCases, id: \.self) { t in
                            Label(t.rawValue, systemImage: t.icon).tag(t)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                Spacer()
            }
        }
    }

    private var hardwareSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Hardware").font(.title3.bold())
                Spacer()
                Button {
                    detectHardware()
                } label: {
                    Label("Detect Hardware", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .disabled(!target.isReachable)
                .help(target.isReachable
                      ? "Auto-fill filesystem and capacity from the mounted volume"
                      : "Volume offline — connect it to detect hardware")
            }
            HStack(alignment: .top, spacing: 24) {
                pickerColumn(title: "Media") {
                    Picker("", selection: Binding(
                        get: { target.mediaTech },
                        set: { model.setMediaTech($0, for: target) }
                    )) {
                        ForEach(VolumeMediaTech.allCases, id: \.self) { m in
                            Label(m.rawValue, systemImage: m.icon).tag(m)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
                pickerColumn(title: "Filesystem") {
                    TextField("APFS, exFAT, …", text: Binding(
                        get: { target.filesystem },
                        set: { model.setFilesystem($0, for: target) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 24) {
                pickerColumn(title: "Purchased (year)") {
                    TextField("YYYY", text: $purchaseYearText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit { commitPurchaseYear() }
                }
                pickerColumn(title: "Capacity (TB)") {
                    TextField("0.0", text: $capacityTBText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit { commitCapacity() }
                }
                Spacer()
            }
        }
    }

    /// Pull filesystem name and total capacity from the live mount via
    /// URLResourceValues. Media tech and purchase year stay user-driven —
    /// macOS doesn't expose "is this RAID-0?" or purchase date.
    private func detectHardware() {
        let url = URL(fileURLWithPath: target.searchPath)
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return }

        if let fs = values.volumeLocalizedFormatDescription, !fs.isEmpty {
            model.setFilesystem(fs, for: target)
        }
        if let bytes = values.volumeTotalCapacity, bytes > 0 {
            let tb = Double(bytes) / 1_000_000_000_000.0
            model.setCapacityTB(tb, for: target)
            capacityTBText = String(format: "%.2f", tb)
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes").font(.title3.bold())
            TextEditor(text: Binding(
                get: { target.notes },
                set: { model.setNotes($0, for: target) }
            ))
            .font(.system(size: 14))
            .frame(minHeight: 100, maxHeight: 220)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
        }
    }

    // MARK: Helpers

    private func pickerColumn<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout)
                .foregroundColor(.secondary)
            content()
        }
    }

    private func syncTextFields() {
        purchaseYearText = target.purchaseYear.map(String.init) ?? ""
        capacityTBText = target.capacityTB.map { String(format: "%.2f", $0) } ?? ""
    }

    private func commitPurchaseYear() {
        let trimmed = purchaseYearText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            model.setPurchaseYear(nil, for: target)
        } else if let y = Int(trimmed), (1990...2100).contains(y) {
            model.setPurchaseYear(y, for: target)
        } else {
            purchaseYearText = target.purchaseYear.map(String.init) ?? ""
        }
    }

    private func commitCapacity() {
        let trimmed = capacityTBText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            model.setCapacityTB(nil, for: target)
        } else if let v = Double(trimmed), v > 0 {
            model.setCapacityTB(v, for: target)
        } else {
            capacityTBText = target.capacityTB.map { String(format: "%.2f", $0) } ?? ""
        }
    }
}
