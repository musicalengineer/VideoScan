// CatalogAuditDetailView.swift
// Double-click detail for the "Audit catalog" MFO row: the running totals,
// the folders that lost files, one line per drive (N of M, checking /
// finished / disconnected), every row that was not simply present with
// its reason, then the first present rows (the job keeps at most
// CatalogAuditJob.sampleCap). Pure presentation over the job's published
// arrays — no model access, no I/O, nothing O(catalog) in the body.

import SwiftUI

struct CatalogAuditDetailView: View {
    @ObservedObject var job: CatalogAuditJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.totals.line)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            let folders = job.totals.goneFoldersClause
            if !folders.isEmpty {
                Label(folders, systemImage: "folder.badge.questionmark")
                    .font(.system(size: 11))
                    .foregroundStyle(Self.color(.gone))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(job.lanes) { laneRow($0) }
            if job.problems.isEmpty && job.sample.isEmpty {
                Text(job.state.isActive ? "Nothing checked yet…" : "No row was asked.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(job.problems) { row($0) }
                        ForEach(job.sample) { row($0) }
                        let shown = job.sample.count
                        if job.totals[.present] > shown {
                            Text("…and \((job.totals[.present] - shown).formatted()) more present")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(NSColor.textBackgroundColor).opacity(0.5)))
        .accessibilityIdentifier("mfo.auditCatalog.detail")
    }

    private func laneRow(_ lane: CatalogAuditLaneStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(lane.label)
                .font(.system(size: 12, weight: .medium))
            Text("\(lane.done.formatted()) of \(lane.planned.formatted()) · \(Self.words(lane.phase))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func row(_ item: CatalogAuditRow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.icon(item.result))
                .foregroundStyle(Self.color(item.result))
                .font(.system(size: 12))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(item.filename)  ·  \(item.drive)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.path)
                Text(item.result == .present ? item.detail : "\(item.result.words) — \(item.detail)")
                    .font(.system(size: 11))
                    .foregroundStyle(item.result.needsAPerson ? Self.color(item.result) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    static func words(_ phase: CatalogAuditLaneStatus.Phase) -> String {
        switch phase {
        case .waiting: return "waiting"
        case .checking: return "checking"
        case .finished: return "finished"
        case .disconnected: return "drive not connected"
        case .stopped: return "stopped"
        }
    }

    static func icon(_ result: CatalogAuditResult) -> String {
        switch result {
        case .present: return "checkmark.circle.fill"
        case .cameBack: return "arrow.uturn.backward.circle.fill"
        case .gone, .goneArchived, .stillMissing, .neverSeenByAnAudit: return "questionmark.folder"
        case .changed: return "exclamationmark.triangle.fill"
        case .couldNotCheck: return "xmark.octagon.fill"
        case .notAsked: return "externaldrive.badge.xmark"
        case .recordChanged: return "arrow.triangle.2.circlepath"
        }
    }

    static func color(_ result: CatalogAuditResult) -> Color {
        switch result {
        case .present, .cameBack: return Color(red: 0.10, green: 0.45, blue: 0.25)
        case .gone, .goneArchived, .neverSeenByAnAudit, .couldNotCheck: return Color(red: 0.80, green: 0.10, blue: 0.10)
        case .changed: return Color(red: 0.75, green: 0.45, blue: 0.00)
        default: return .secondary
        }
    }
}
