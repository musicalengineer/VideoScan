// CatalogDatabaseInfoView.swift — the compact window behind Catalog ▸
// Catalog Database Info… (CatalogDatabaseInfo.swift holds the read and the
// words). HIG: system fonts, label/value rows in a Grid, the schema line
// first and large, Copy and Done at the bottom, nothing editable. The body
// only lays out `model.lines` (~14 strings) — no reads, no counts.

import SwiftUI

struct CatalogDatabaseInfoView: View {
    static let sceneID = "catalog-database-info"
    static let windowTitle = "Catalog Database"
    static let menuTitle = "Catalog Database Info…"

    @StateObject private var model: CatalogDatabaseInfoModel
    @Environment(\.dismiss) private var dismiss

    init(sources: @escaping @MainActor () -> CatalogDatabaseInfoSources) {
        _model = StateObject(wrappedValue: CatalogDatabaseInfoModel(sources: sources))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let first = model.lines.first {
                Text(first.value)
                    .font(.title.bold())
                    .foregroundStyle(first.known ? .primary : .secondary)
                    .textSelection(.enabled)
                    .help(first.source)
            } else {
                Text(model.isReading ? "Reading…" : " ").font(.title.bold()).foregroundStyle(.secondary)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(model.lines.dropFirst()) { line in
                    GridRow {
                        Text(line.label + ":")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(line.value)
                            .foregroundStyle(line.known ? .primary : .secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .help(line.source)
                }
            }
            Divider()
            HStack {
                if let readAt = model.readAt {
                    Text("Read \(readAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
                    .disabled(model.isReading)
                Button("Copy") { model.copyToClipboard() }
                    .disabled(model.lines.isEmpty)
                    .help("Put these lines on the clipboard as plain text")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, maxWidth: 900, alignment: .topLeading)
        .task { await model.refresh() }
    }
}

/// Catalog ▸ Catalog Database Info… — opens the window above. Works with
/// nothing selected; never ⌘I (that is the per-volume Catalog Info).
struct CatalogDatabaseInfoMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(CatalogDatabaseInfoView.menuTitle) {
            openWindow(id: CatalogDatabaseInfoView.sceneID)
        }
        .help("Facts about the catalog database itself — schema, size, generation, counts, last commit, backup, role, journal and the last Validate Catalog — read from the file now. Read-only.")
    }
}
