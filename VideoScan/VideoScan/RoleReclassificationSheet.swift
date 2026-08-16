//
//  RoleReclassificationSheet.swift
//  VideoScan
//
//  One-time prompt from the volume-role taxonomy migration (2026-08-16).
//  Targets whose persisted role was "Archive" but which are NOT the
//  designated Master Archive land in `model.pendingRoleReclassifications`;
//  `.archive` now means THE Master Archive, so we ask rather than rename.
//  Per row: a picker limited to Original / Backup / Working (default
//  Original). "Apply" commits every row; "Decide later" leaves the queue
//  intact so the sheet returns on the next Volumes-window open.
//

import SwiftUI

struct RoleReclassificationSheet: View {
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss

    /// The roles offered per row — a strict subset of `pickerCases`:
    /// Unassigned/Offsite are not answers to "was this an original or a
    /// backup of the archive?". Default is Original (the conservative
    /// answer: a source of truth, never treated as an expendable copy).
    static let choices: [VolumeRole] = [.original, .backup, .working]
    static let defaultChoice: VolumeRole = .original

    /// Per-target selection, keyed by target id. Swift `Dictionary` ≈
    /// C++ `std::unordered_map`; missing key falls back to the default.
    @State private var selection: [UUID: VolumeRole] = [:]

    private var pending: [CatalogScanTarget] { model.pendingRoleReclassifications }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "archivebox.fill")
                    .font(.title2)
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("These volumes were marked Archive")
                        .font(.title3.bold())
                    Text("Only the Master Archive can be Archive now — pick a role for each.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(pending, id: \.id) { target in
                        row(for: target)
                    }
                }
            }
            .frame(minHeight: 60, maxHeight: 320)

            HStack {
                Button("Decide later") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("roleReclassification.later")
                Spacer()
                Button("Apply") { applyAll() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(pending.isEmpty)
                    .accessibilityIdentifier("roleReclassification.apply")
            }
        }
        .padding(20)
        .frame(minWidth: 520)
        .onAppear { seedDefaults() }
        .onChange(of: pending.map(\.id)) { seedDefaults() }
    }

    @ViewBuilder
    private func row(for target: CatalogScanTarget) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(VolumeReachability.displayLabel(forPath: target.searchPath))
                    .font(.system(size: 14, weight: .medium))
                Text(target.searchPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { selection[target.id] ?? Self.defaultChoice },
                set: { selection[target.id] = $0 }
            )) {
                ForEach(Self.choices, id: \.self) { r in
                    Label(r.rawValue, systemImage: r.icon).tag(r)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .accessibilityIdentifier("roleReclassification.picker.\(target.id.uuidString)")
        }
        .padding(.vertical, 2)
    }

    private func seedDefaults() {
        for t in pending where selection[t.id] == nil {
            selection[t.id] = Self.defaultChoice
        }
    }

    private func applyAll() {
        // Snapshot first — resolving mutates `pending` under us.
        let targets = pending
        for t in targets {
            model.resolveRoleReclassification(t, to: selection[t.id] ?? Self.defaultChoice)
        }
        dismiss()
    }
}
