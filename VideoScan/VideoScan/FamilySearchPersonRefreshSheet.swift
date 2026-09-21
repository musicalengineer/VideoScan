// FamilySearchPersonRefreshSheet.swift
// The two views behind "Refresh from FamilySearch…" (Rick, 2026-09-21):
//
//   • PersonRefreshBanner — a one-line strip above the Family Tree while a
//     refresh is in flight: "waiting for Terminal" with Cancel, "FamilySearch
//     answered — N changes" with Review…, the refusal sentence, or "applied"
//     with Undo. Non-blocking by design; the tree stays usable.
//   • PersonRefreshReviewSheet — old | new per changed field, a checkbox on
//     each (all on), relationship differences listed as NOT applied, and
//     Apply / Cancel. No changes → "Already matches FamilySearch."
//
// Neither view reads disk or walks the tree in `body`: everything shown
// comes from the coordinator's `phase` (the diff is computed once, off the
// main actor, when the file lands).

import SwiftUI

struct PersonRefreshBanner: View {
    @ObservedObject var coordinator: PersonRefreshCoordinator
    let onReview: () -> Void
    let onCancel: () -> Void
    let onUndo: () -> Void
    let onDismiss: () -> Void

    private var name: String { coordinator.target.personName }

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
        .accessibilityIdentifier("tree.personRefresh.banner")
    }

    @ViewBuilder private var content: some View {
        switch coordinator.phase {
        case .idle:
            EmptyView()
        case .waiting:
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Refreshing \(name) from FamilySearch — finish in the Terminal window "
                     + "(it asks for your FamilySearch username and password).")
                if let since = coordinator.quietSince {
                    Text(PersonRefreshBanner.quietText(since: since))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Cancel", action: onCancel)
                .accessibilityIdentifier("tree.personRefresh.cancel")
        case .parsing:
            ProgressView().controlSize(.small)
            Text("Reading what FamilySearch sent for \(name)…")
            Spacer()
            Button("Cancel", action: onCancel)
        case .ready(let diff):
            Image(systemName: "arrow.triangle.2.circlepath")
            Text(diff.factsMatch
                 ? "\(name) already matches FamilySearch."
                 : "FamilySearch answered for \(name): \(diff.changes.count) "
                    + "change\(diff.changes.count == 1 ? "" : "s") to review.")
            Spacer()
            Button(diff.factsMatch ? "Details…" : "Review…", action: onReview)
                .accessibilityIdentifier("tree.personRefresh.review")
            Button("Cancel", action: onCancel)
        case .applied(let fields):
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
            Text(fields == 0
                 ? "Nothing applied to \(name)."
                 : "Applied \(fields) refreshed fact\(fields == 1 ? "" : "s") to \(name).")
            Spacer()
            if fields > 0 {
                Button("Undo", action: onUndo)
                    .accessibilityIdentifier("tree.personRefresh.undo")
            }
            Button("Dismiss", action: onDismiss)
        case .refused(let message), .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss", action: onDismiss)
        }
    }

    /// Pure so a test can pin the wording.
    nonisolated static func quietText(since: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        let span = seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min"
        return "Nothing yet for \(span) — Terminal may be waiting for you (press Return, then your username and password). Still watching."
    }
}

struct PersonRefreshReviewSheet: View {
    @ObservedObject var coordinator: PersonRefreshCoordinator
    let diff: PersonRefreshDiff
    let onApplied: () -> Void
    let onClose: () -> Void

    /// Field keys ticked for Apply — all on by default.
    @State private var selected: Set<String>

    init(coordinator: PersonRefreshCoordinator, diff: PersonRefreshDiff,
         onApplied: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.coordinator = coordinator
        self.diff = diff
        self.onApplied = onApplied
        self.onClose = onClose
        _selected = State(initialValue: Set(diff.changes.map(\.field.key)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Refresh \(coordinator.target.personName) from FamilySearch")
                .font(.system(size: 15, weight: .semibold))
            Text(coordinator.target.familySearchID)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            if diff.factsMatch {
                Label("Already matches FamilySearch.", systemImage: "checkmark.seal")
                    .font(.system(size: 13))
                    .accessibilityIdentifier("tree.personRefresh.alreadyMatches")
            } else {
                changesTable
            }

            if !diff.relationshipNotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Relationships (not changed here)")
                        .font(.system(size: 12, weight: .semibold))
                    ForEach(diff.relationshipNotes) { note in
                        Label(note.sentence, systemImage: "person.2")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("tree.personRefresh.relationshipNotes")
            }

            Text("Apply changes the Family Tree's view of these facts only — never parents, spouses or children, "
                 + "never your GEDCOM files, never a People profile. Undo is on the person's right-click menu; "
                 + "a later full tree pull replaces these facts.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(diff.factsMatch ? "Close" : "Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("tree.personRefresh.cancelSheet")
                if !diff.factsMatch {
                    Button("Apply \(selected.count)") {
                        if coordinator.apply(selectedFieldKeys: selected) { onApplied() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
                    .accessibilityIdentifier("tree.personRefresh.apply")
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var changesTable: some View {
        // `Grid` ≈ a table layout whose columns size to their widest cell.
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("")
                Text("Field").font(.system(size: 11, weight: .semibold))
                Text("In the tree now").font(.system(size: 11, weight: .semibold))
                Text("FamilySearch says").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            ForEach(diff.changes) { change in
                GridRow {
                    Toggle("", isOn: Binding(
                        get: { selected.contains(change.field.key) },
                        set: { on in
                            if on { selected.insert(change.field.key) } else { selected.remove(change.field.key) }
                        }))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    Text(change.label).font(.system(size: 12, weight: .medium))
                    Text(change.old ?? "—")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(change.new ?? "— (none on FamilySearch)")
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityIdentifier("tree.personRefresh.changes")
    }
}
