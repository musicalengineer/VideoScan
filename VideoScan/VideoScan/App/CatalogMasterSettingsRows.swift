// CatalogMasterSettingsRows.swift — the "Catalog Master" rows at the top of
// Settings, above Model Configuration (Rick 2026-11-02). One field (the
// master's name), one button (this Mac), one line that says what this Mac
// is as a result and whether a relaunch is needed. Words from
// CatalogMasterSetting (pure, tested); the one setter is the store's.

import SwiftUI

struct CatalogMasterSettingsRows: View {
    @ObservedObject var store: CatalogMasterStore
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Catalog Master", systemImage: "crown")
                .font(.headline)
                .foregroundColor(.blue)
            HStack(spacing: 8) {
                Text("Catalog master:")
                TextField("Mac name, e.g. RicksUltra.local", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { store.setMaster(draft) }
                    .accessibilityIdentifier("settings.catalogMaster.hostname")
                Button("Use This Mac") { store.useThisMac() }
                    .disabled(store.role == .master && store.explicit)
                    .accessibilityIdentifier("settings.catalogMaster.useThisMac")
            }
            HStack(spacing: 6) {
                Image(systemName: store.role == .master ? "crown.fill" : "eye")
                    .font(.system(size: 10))
                    .foregroundStyle(store.role == .master ? Color.blue : Color.secondary)
                Text(store.words)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.catalogMaster.role")
            Text("One Mac is the master and writes the catalog; every other Mac names it here and views a synced, read-only copy. Press Return to set a name; the role is decided when VideoScan launches.")
                .font(.footnote).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { draft = store.master }
        .onChange(of: store.master) { _, new in draft = new }
    }
}
