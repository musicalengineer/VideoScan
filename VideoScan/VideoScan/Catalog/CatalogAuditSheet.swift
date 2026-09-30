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
    @AppStorage("selectedTab") private var selectedTab: Int = 0
    /// "Fix it for me" confirmation — `.alert(item:)` so the plan text
    /// travels with the presentation (chained-sheet antipattern memo).
    @State private var pendingFix: PendingFix? = nil
    private struct PendingFix: Identifiable { let id = UUID(); let fix: CatalogAuditFix; let check: String }
    @State private var lastFixSummary: String? = nil

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
        .alert(item: $pendingFix) { p in
            Alert(
                title: Text("Fix \"\(p.check)\"?"),
                message: Text(p.fix.plan + "\n\nThe catalog is saved afterwards and the audit re-runs."),
                primaryButton: .default(Text(p.fix.buttonTitle)) {
                    let outcome = CatalogAuditFixer.apply(p.fix, model: model)
                    lastFixSummary = outcome.summary
                    report = nil
                    run()
                },
                secondaryButton: .cancel()
            )
        }
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
            if let s = lastFixSummary {
                Label(s, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundColor(.green)
                    .lineLimit(1)
            }
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
            // "Show me" — takes you to the place you can fix it (Rick
            // 2026-08-19). Findings without a destination rely on the
            // detail line as the advice bubble.
            if f.status != .pass {
                VStack(alignment: .trailing, spacing: 6) {
                    // "Fix it for me" — deterministic in-app repair with a
                    // plan + confirmation (Rick 2026-08-19).
                    if let fix = f.fix {
                        Button {
                            pendingFix = PendingFix(fix: fix, check: f.check)
                        } label: {
                            Label("Fix it for me", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help(fix.plan)
                        .accessibilityIdentifier("catalogAudit.fix.\(f.check)")
                    }
                    if f.action != .none {
                        Button {
                            perform(f.action)
                        } label: {
                            Label(showMeTitle(f.action), systemImage: "arrow.right.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(showMeHelp(f.action))
                        .accessibilityIdentifier("catalogAudit.showMe.\(f.check)")
                    }
                }
            }
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

    private func showMeTitle(_ a: CatalogAuditAction) -> String {
        switch a {
        case .focusRecords(let ids, _): return "Show \(ids.count.formatted()) in Catalog"
        case .selectVolume:             return "Show drive"
        case .none:                     return ""
        }
    }
    private func showMeHelp(_ a: CatalogAuditAction) -> String {
        switch a {
        case .focusRecords: return "Opens the Catalog tab filtered to just these records, so you can Update Catalog, Unpair, or delete them."
        case .selectVolume: return "Selects that drive in the Storage sidebar — right-click it for Delete from list / Update Catalog."
        case .none:         return ""
        }
    }
    private func perform(_ a: CatalogAuditAction) {
        switch a {
        case .focusRecords(let ids, let label):
            model.pendingCatalogSelection = nil
            model.pendingFocusLabel = label
            model.focusedMediaIDs = Set(ids)
            selectedTab = 1                      // Catalog
            MainWindowHelper.shared.openMainWindow()
        case .selectVolume(let path):
            if let t = model.scanTargets.first(where: { $0.searchPath == path }) {
                model.pendingVolumesSelectionID = t.id
            }
        case .none:
            return
        }
        dismiss()
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
