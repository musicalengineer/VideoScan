// CatalogDatabaseInfoView.swift — the database facts as label/value rows
// (CatalogDatabaseInfo.swift holds the read and the words). Built 11/01 as
// its own window behind Catalog ▸ Catalog Database Info…; the same day's
// regrouping (DECISIONS 2026-11-01) moved the rows into the Catalog Status
// window, under its three lines — the menu item and the window are gone,
// the rows and their read are unchanged. HIG: system fonts, label/value rows
// in a Grid, nothing editable. The body only lays out `model.lines`
// (~14 strings) — no reads, no counts.

import SwiftUI

struct CatalogDatabaseInfoRows: View {
    @ObservedObject var model: CatalogDatabaseInfoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.lines.isEmpty {
                Text(model.isReading ? "Reading…" : " ").foregroundStyle(.secondary)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(model.lines) { line in
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
            }
        }
        .accessibilityIdentifier("catalogStatus.databaseFacts")
    }
}
