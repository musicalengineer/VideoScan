// CatalogAuditSheet.swift
// Presents a CatalogAuditReport (Storage tab ▸ Catalog row ▸ right-click
// ▸ Audit Catalog…). Runs the audit off the main thread, lists each check
// with a pass/warn/fail glyph, and offers Copy Report.

import SwiftUI

struct CatalogAuditSheet: View {
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    @State private var report: CatalogAuditReport? = nil
    @State private var task: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            if let r = report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(r.findings) { f in findingRow(f) }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                ProgressView("Adding everything up…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 460, idealHeight: 600)
        .task { run() }
        .onDisappear { task?.cancel() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: glyph(report?.overall))
                .font(.system(size: 30))
                .foregroundColor(color(report?.overall))
            VStack(alignment: .leading, spacing: 2) {
                Text("Catalog audit")
                    .font(.title2.bold())
                Text(report.map { r in
                    "\(r.activeRecords.formatted()) present records · \(CatalogStorageTotals.displaySize(r.activeBytes)) · \(r.failCount) fail, \(r.warnCount) warn · \(String(format: "%.2f", r.duration)) s"
                } ?? "Checking that the catalog adds up…")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                report = nil
                run()
            } label: { Label("Run again", systemImage: "arrow.clockwise") }
            .disabled(report == nil)
        }
    }

    private func findingRow(_ f: CatalogAuditFinding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph(f.status))
                .foregroundColor(color(f.status))
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(f.check).font(.headline)
                    Text(f.headline).font(.body)
                }
                if !f.detail.isEmpty {
                    Text(f.detail).font(.callout).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(f.examples, id: \.self) { e in
                    Text("· \(e)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(color(f.status).opacity(f.status == .pass ? 0.05 : 0.10)))
    }

    private var footer: some View {
        HStack {
            Button {
                if let r = report {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(r.text, forType: .string)
                }
            } label: { Label("Copy Report", systemImage: "doc.on.doc") }
            .disabled(report == nil)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func run() {
        task?.cancel()
        let inputs = CatalogAuditor.project(model: model)
        task = Task {
            let r = await Task.detached(priority: .userInitiated) { CatalogAuditor.run(inputs) }.value
            if Task.isCancelled { return }
            report = r
            model.log("Catalog audit: \(r.overall.rawValue.uppercased()) — \(r.failCount) fail, \(r.warnCount) warn over \(r.activeRecords) present records")
        }
    }

    private func glyph(_ s: CatalogAuditStatus?) -> String {
        switch s {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        case nil:   return "list.bullet.clipboard"
        }
    }
    private func color(_ s: CatalogAuditStatus?) -> Color {
        switch s {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        case nil:   return .secondary
        }
    }
}
