// PruneBarSettingsSection.swift
// Settings → "Protection bar" (promote-and-prune stage 2, Rick 2026-09-12):
// copies required per importance level before extra copies may go to the
// Trash. Three rows, the design's defaults, editable. @AppStorage keys are
// ImportanceBar.Key.* — the plan reads the same keys through
// ImportanceBar.load(defaults:), so this pane and the sheet agree by
// construction.
//
// The verified archive copy is always required and is not a knob.

import SwiftUI

struct PruneBarSettingsSection: View {

    @AppStorage(ImportanceBar.Key.importantDevices) private var importantDevices = ImportanceBar.defaults.important.extraDevices
    @AppStorage(ImportanceBar.Key.importantCloudOrOffsite) private var importantCloud = ImportanceBar.defaults.important.cloudOrOffsite
    @AppStorage(ImportanceBar.Key.ordinaryDevices) private var ordinaryDevices = ImportanceBar.defaults.ordinary.extraDevices
    @AppStorage(ImportanceBar.Key.ordinaryCloudOrOffsite) private var ordinaryCloud = ImportanceBar.defaults.ordinary.cloudOrOffsite
    @AppStorage(ImportanceBar.Key.lowDevices) private var lowDevices = ImportanceBar.defaults.low.extraDevices
    @AppStorage(ImportanceBar.Key.lowCloudOrOffsite) private var lowCloud = ImportanceBar.defaults.low.cloudOrOffsite

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Protection bar", systemImage: "shield.lefthalf.filled")
                .font(.headline)
                .foregroundColor(.indigo)
            Text("After a Promote, extra copies of a file may go to the Trash only once the file has this much protection. The verified archive copy is always required. The level comes from the stars and disposition you already set.")
                .font(.footnote).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            barRow(ImportanceBar.Level.important.displayName, devices: $importantDevices, cloud: $importantCloud)
            barRow(ImportanceBar.Level.ordinary.displayName, devices: $ordinaryDevices, cloud: $ordinaryCloud)
            barRow(ImportanceBar.Level.low.displayName, devices: $lowDevices, cloud: $lowCloud)

            Button("Reset bar to defaults") {
                let d = ImportanceBar.defaults
                importantDevices = d.important.extraDevices; importantCloud = d.important.cloudOrOffsite
                ordinaryDevices = d.ordinary.extraDevices; ordinaryCloud = d.ordinary.cloudOrOffsite
                lowDevices = d.low.extraDevices; lowCloud = d.low.cloudOrOffsite
            }
            .controlSize(.small)
        }
    }

    private func barRow(_ title: String, devices: Binding<Int>, cloud: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 130, alignment: .leading)
            Stepper(value: devices, in: 0...3) {
                Text("+ \(devices.wrappedValue) more device\(devices.wrappedValue == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .monospacedDigit()
            }
            .frame(width: 190, alignment: .leading)
            Toggle("cloud or off-site copy", isOn: cloud)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
