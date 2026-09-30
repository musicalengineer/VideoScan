// VerifyArchiveDetailView.swift
// Expanded result panel for a Verify Archive Copies row in the Media
// File Operations window: one line per outcome, mismatches first and
// loud (GH #167 — the mismatch is the one thing this tool must never
// let a user skim past). Pure presentation over the job's published
// `outcomes`; no model access, no I/O.

import SwiftUI

struct VerifyArchiveDetailView: View {
    @ObservedObject var job: VerifyArchiveCopiesJob

    /// Mismatches and failures float to the top; within a band the
    /// job's own (path-sorted) order is kept.
    private var sortedOutcomes: [VerifyArchiveCopiesJob.FileOutcome] {
        job.outcomes.enumerated().sorted { a, b in
            let (ra, rb) = (Self.rank(a.element.kind), Self.rank(b.element.kind))
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map(\.element)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if job.outcomes.isEmpty {
                Text("Nothing checked yet…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(sortedOutcomes) { outcome in
                            row(outcome)
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

    @ViewBuilder
    private func row(_ outcome: VerifyArchiveCopiesJob.FileOutcome) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.icon(outcome.kind))
                .foregroundStyle(Self.color(outcome.kind))
                .font(.system(size: 12))
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(outcome.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Self.label(outcome.kind))
                        .font(.system(size: 10, weight: .bold).smallCaps())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Self.color(outcome.kind)))
                }
                Text(outcome.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(outcome.kind == .mismatch ? Self.color(.mismatch) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Presentation tables (static so tests could pin them)

    static func rank(_ kind: VerifyArchiveCopiesJob.FileOutcome.Kind) -> Int {
        switch kind {
        case .mismatch: return 0
        case .failed: return 1
        case .missing: return 2
        case .changedUnderVerify: return 3
        case .unmanifested: return 4
        case .orphan: return 5
        case .restored: return 6
        case .verified: return 7
        }
    }

    static func label(_ kind: VerifyArchiveCopiesJob.FileOutcome.Kind) -> String {
        switch kind {
        case .verified: return "Verified"
        case .restored: return "Restored"
        case .mismatch: return "Mismatch"
        case .missing: return "Missing"
        case .orphan: return "Manifest only"
        case .unmanifested: return "Unmanifested"
        case .failed: return "Failed"
        case .changedUnderVerify: return "Changed under Verify"
        }
    }

    static func icon(_ kind: VerifyArchiveCopiesJob.FileOutcome.Kind) -> String {
        switch kind {
        case .verified: return "checkmark.seal.fill"
        case .restored: return "checkmark.seal.fill"
        case .mismatch: return "exclamationmark.octagon.fill"
        case .missing: return "questionmark.folder.fill"
        case .orphan: return "doc.badge.ellipsis"
        case .unmanifested: return "doc.badge.plus"
        case .failed: return "xmark.circle.fill"
        case .changedUnderVerify: return "arrow.triangle.2.circlepath"
        }
    }

    static func color(_ kind: VerifyArchiveCopiesJob.FileOutcome.Kind) -> Color {
        switch kind {
        case .verified: return Color(red: 0.10, green: 0.55, blue: 0.25)
        case .restored: return Color(red: 0.00, green: 0.45, blue: 0.55)
        case .mismatch: return Color(red: 0.80, green: 0.10, blue: 0.10)
        case .missing: return Color(red: 0.85, green: 0.45, blue: 0.00)
        case .orphan: return Color.gray
        case .unmanifested: return Color(red: 0.65, green: 0.50, blue: 0.05)
        case .failed: return Color(red: 0.70, green: 0.14, blue: 0.16)
        case .changedUnderVerify: return Color(red: 0.55, green: 0.40, blue: 0.10)
        }
    }
}
