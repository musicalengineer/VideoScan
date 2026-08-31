// FamilyTreeVerifyReportView.swift
// The review queue behind the red badge (Rick, 2026-08-30): "a user can
// review so-many per session if there are a lot."
//
// A LIST, not a wizard. Rick's real tree returns 442 entries needing
// review; a modal that marches you through them one at a time turns a
// browsable to-do list into a chore you abandon halfway. This is meant to
// be opened, skimmed, acted on twice, and closed.
//
// Every row is READ-ONLY. Nothing here edits the tree. A duplicate is
// resolved on familysearch.org — which is why each row offers the person
// and the FamilySearch link rather than a Merge button. Rick's own note on
// FamilySearch has been waiting since February 2025 precisely because he
// thought he was not allowed to act; the link is the shortest path to
// finding out he is.

import SwiftUI
import VideoScanCore

struct FamilyTreeVerifyReportView: View {
    let report: FamilyTreeVerification.Report
    /// Jump to a person in the tree behind the sheet.
    let onReveal: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kindFilter: FamilyTreeVerification.Kind?

    private var shown: [FamilyTreeVerification.Finding] {
        let needing = report.findings.filter { $0.severity <= .review }
        guard let kindFilter else { return needing }
        return needing.filter { $0.kind == kindFilter }
    }

    /// Kinds present in this report, commonest first, so the filter row
    /// reflects the tree rather than the enum.
    private var kindsPresent: [(FamilyTreeVerification.Kind, Int)] {
        Dictionary(grouping: report.findings.filter { $0.severity <= .review }, by: \.kind)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            filters
            Divider()
            if shown.isEmpty {
                ContentUnavailableView("Nothing to review",
                                       systemImage: "checkmark.circle",
                                       description: Text("No entries match this filter."))
                    .frame(maxHeight: .infinity)
            } else {
                List(shown) { finding in
                    FindingRow(finding: finding, onReveal: onReveal)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Entries needing review").font(.title2.weight(.semibold))
                Text("\(report.needingReview) of \(report.findings.count) findings "
                     + "across \(report.peopleChecked) people")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", count: report.needingReview, kind: nil)
                ForEach(kindsPresent, id: \.0) { kind, count in
                    chip(Self.label(kind), count: count, kind: kind)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private func chip(_ title: String, count: Int,
                      kind: FamilyTreeVerification.Kind?) -> some View {
        let selected = kindFilter == kind
        return Button {
            kindFilter = selected ? nil : kind
        } label: {
            Text("\(title) (\(count))")
                .font(.system(size: 11))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.25)
                                                    : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    static func label(_ kind: FamilyTreeVerification.Kind) -> String {
        switch kind {
        case .duplicatePerson:     "Possible duplicates"
        case .deathBeforeBirth:    "Died before born"
        case .implausibleLifespan: "Impossible lifespan"
        case .parentTooYoung:      "Parent too young"
        case .ancestorCycle:       "Own ancestor"
        case .unattachedPerson:    "Connected to nobody"
        case .placeholderValue:    "Placeholder value"
        }
    }
}

private struct FindingRow: View {
    let finding: FamilyTreeVerification.Finding
    let onReveal: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: finding.severity == .error
                      ? "exclamationmark.triangle.fill" : "questionmark.circle")
                    .foregroundStyle(finding.severity == .error ? .orange : .secondary)
                    .font(.system(size: 11))
                Text(FamilyTreeVerifyReportView.label(finding.kind))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(finding.personNames.joined(separator: "  ·  "))
                .font(.system(size: 13, weight: .medium))
            Text(finding.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ForEach(Array(finding.personIDs.enumerated()), id: \.offset) { index, id in
                    Button("Show \(finding.personNames[safe: index] ?? "person")") {
                        onReveal(id)
                    }
                    .buttonStyle(.link).font(.system(size: 11))
                }
                // A duplicate is resolved on familysearch.org, not here.
                ForEach(finding.familySearchIDs, id: \.self) { fsid in
                    Link("FamilySearch \(fsid)",
                         destination: URL(string: "https://www.familysearch.org/tree/person/details/\(fsid)")!)
                        .font(.system(size: 11))
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
