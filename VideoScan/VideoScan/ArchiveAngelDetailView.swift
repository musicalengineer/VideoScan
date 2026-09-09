// ArchiveAngelDetailView.swift
// Expanded panel for an Archive Angel row in the Media File Operations
// window: one line per plan entry (status, step chips, first why-line)
// and the rejection summary. Pure presentation over the job's published
// plan — the full review happens in the Archive tab's sheet.

import SwiftUI

struct ArchiveAngelDetailView: View {
    @ObservedObject var job: ArchiveAngelJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if job.plan.entries.isEmpty {
                Text(job.state.isActive ? "Walking the catalog…" : "No candidates in this batch.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(job.plan.entries) { entry in
                            row(entry)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(NSColor.textBackgroundColor).opacity(0.5)))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("\(job.plan.readyCount) ready · \(job.plan.entries.count) picked · "
                 + "\(job.plan.rejectedTotal) rejected · \(job.plan.overflow) more would qualify")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Text(job.plan.batchDir)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    @ViewBuilder
    private func row(_ entry: ArchiveAngelPlan.Entry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.icon(entry.status))
                .foregroundStyle(Self.color(entry.status))
                .font(.system(size: 12))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.filename).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text("\(entry.score)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    ForEach(entry.steps) { step in chip(step) }
                }
                if let why = entry.evidence.first?.line {
                    Text(why).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                if let f = entry.failure {
                    Text(f).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
                }
            }
        }
    }

    private func chip(_ step: ArchiveAngelPlan.StepOutcome) -> some View {
        Text(step.kind.label)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Self.chipColor(step.state).opacity(0.18)))
            .foregroundStyle(Self.chipColor(step.state))
            .help(step.note.isEmpty ? step.kind.label : step.note)
    }

    static func icon(_ s: ArchiveAngelPlan.EntryStatus) -> String {
        switch s {
        case .pending: return "circle.dotted"
        case .preparing: return "gearshape"
        case .ready: return "checkmark.circle.fill"
        case .promoted: return "archivebox.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    static func color(_ s: ArchiveAngelPlan.EntryStatus) -> Color {
        switch s {
        case .pending: return .secondary
        case .preparing: return .orange
        case .ready: return .green
        case .promoted: return .blue
        case .failed: return .red
        }
    }

    static func chipColor(_ s: ArchiveAngelPlan.StepState) -> Color {
        switch s {
        case .pending: return .secondary
        case .done: return .green
        case .skipped: return .gray
        case .failed: return .red
        }
    }
}
