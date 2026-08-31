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
//
// SIZING (Rick, 2026-08-31): the category row used to be a single
// horizontal scroller, so the categories past the right edge were
// invisible rather than merely off-screen — you cannot click a filter you
// do not know exists. The chips now WRAP, so every category is visible at
// any width, and the sheet opens wide with a flexible frame.
//
// ERA (Rick, same day): "anything before 1800 has little chance of being
// fixed by me ... after 1800 or 1900, these are ones I might be able to
// focus on." Hence the era filter. It hides only what it KNOWS is out of
// range: an undated finding stays visible under every era, because a
// missing date is not evidence of age, and a filter that quietly buries
// fixable work is worse than no filter.

import SwiftUI
import VideoScanCore

struct FamilyTreeVerifyReportView: View {
    let report: FamilyTreeVerification.Report
    /// Jump to a person in the tree behind the sheet.
    let onReveal: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kindFilter: FamilyTreeVerification.Kind?
    @State private var era: Era = .all

    /// How far back the reader is willing to look. Rick can act on the
    /// recent end of the tree and not on the colonial end.
    enum Era: Int, CaseIterable, Identifiable {
        case all = 0
        case since1800 = 1800
        case since1900 = 1900

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .all:       "All years"
            case .since1800: "1800 onward"
            case .since1900: "1900 onward"
            }
        }

        /// Undated findings pass every era on purpose — see the file note.
        func admits(_ finding: FamilyTreeVerification.Finding) -> Bool {
            guard self != .all, let year = finding.year else { return true }
            return year >= rawValue
        }
    }

    /// Everything a human is being asked to look at, before any filtering.
    private var needingReview: [FamilyTreeVerification.Finding] {
        report.findings.filter { $0.severity <= .review }
    }

    private var inEra: [FamilyTreeVerification.Finding] {
        needingReview.filter(era.admits)
    }

    private var shown: [FamilyTreeVerification.Finding] {
        guard let kindFilter else { return inEra }
        return inEra.filter { $0.kind == kindFilter }
    }

    /// Kinds present in this report FOR THE CHOSEN ERA, commonest first,
    /// so the counts on the chips agree with the list underneath them.
    private var kindsPresent: [(FamilyTreeVerification.Kind, Int)] {
        Dictionary(grouping: inEra, by: \.kind)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 == $1.1 ? label($0.0) < label($1.0) : $0.1 > $1.1 }
    }

    /// How many findings carry no date at all. Worth stating plainly: it
    /// explains why an era filter does not reduce the count as much as the
    /// reader expects.
    private var undatedCount: Int {
        needingReview.filter { $0.year == nil }.count
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
                                       description: Text(emptyReason))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown) { finding in
                    FindingRow(finding: finding, onReveal: onReveal)
                }
                .listStyle(.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Wide enough that the categories and the era control both fit on
        // open, and flexible so the sheet can be dragged larger.
        .frame(minWidth: 940, idealWidth: 1140, maxWidth: .infinity,
               minHeight: 560, idealHeight: 760, maxHeight: .infinity)
    }

    private var emptyReason: String {
        if era != .all && !needingReview.isEmpty {
            "Nothing matches this filter. \(needingReview.count) "
            + "\(needingReview.count == 1 ? "entry" : "entries") "
            + "fall outside \(era.title.lowercased())."
        } else {
            "No entries match this filter."
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Entries needing review").font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private var subtitle: String {
        var s = "\(report.needingReview) of \(report.findings.count) findings "
              + "across \(report.peopleChecked) people"
        if era != .all {
            s += " · showing \(inEra.count) from \(era.title.lowercased())"
        }
        if undatedCount > 0 {
            s += " · \(undatedCount) undated (shown under every era)"
        }
        return s
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Years", selection: $era) {
                ForEach(Era.allCases) { option in
                    Text("\(option.title) (\(count(for: option)))").tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)

            // Wraps instead of scrolling sideways: a category you cannot
            // see is a category you never filter by.
            ChipFlow(spacing: 6) {
                chip("All", count: inEra.count, kind: nil)
                ForEach(kindsPresent, id: \.0) { kind, count in
                    chip(label(kind), count: count, kind: kind)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func count(for option: Era) -> Int {
        needingReview.filter(option.admits).count
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

    private func label(_ kind: FamilyTreeVerification.Kind) -> String {
        Self.label(kind)
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
                // The era at a glance, so the reader can judge "can I even
                // act on this?" without opening FamilySearch.
                if let year = finding.year {
                    Text("· \(String(year))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text("· undated")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
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
