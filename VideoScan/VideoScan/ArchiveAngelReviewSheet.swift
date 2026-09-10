// ArchiveAngelReviewSheet.swift
// Archive Angel — Stage 2: "Recommended To Be Archived"
// (docs/archive_angel_design.md §6). One row per prepared candidate with
// the WHY lines, the companions that were made (and why the others were
// not), an editable archive name, date and notes, and a checkbox. Promote
// hands the selection to ArchiveAngelPromoter → the existing Promote job.
// Cancel keeps the batch (edits persisted). Discard deletes the buffer.

import SwiftUI

/// `.sheet(item:)` payload — id = the plan id so re-presenting the same
/// batch is a no-op for SwiftUI.
struct ArchiveAngelReviewRequest: Identifiable {
    var id: UUID { plan.id }
    let plan: ArchiveAngelPlan
}

struct ArchiveAngelReviewSheet: View {
    @EnvironmentObject var model: VideoScanModel
    /// Forwarded to ArchiveAngelPromoter.promote(plan:model:center:) — intentional.
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject var fileOpsCenter: MediaFileOperationsCenter
    @Environment(\.dismiss) private var dismiss

    @State var plan: ArchiveAngelPlan
    @StateObject private var promoter = ArchiveAngelPromoter()
    @State private var showDiscardConfirm = false
    @State private var showRejected = false
    @State private var expandedWhy: Set<UUID> = []
    /// Rick 2026-09-10: a batch that mixed promoted, failed and ready rows
    /// "was very busy, hard to tell which were already archived, rejected".
    /// Only the rows still waiting on a decision show by default.
    @State private var showSettled = false

    init(plan: ArchiveAngelPlan) {
        _plan = State(initialValue: plan)
    }

    private var isPromoting: Bool { plan.status == .promoting }
    private var isDone: Bool { plan.status == .promoted }
    private var readyEntries: [ArchiveAngelPlan.Entry] { plan.entries.filter { $0.status == .ready } }
    private var settledEntries: [ArchiveAngelPlan.Entry] { plan.entries.filter { $0.status != .ready } }
    private var visibleEntries: [ArchiveAngelPlan.Entry] { showSettled ? plan.entries : readyEntries }
    private var selectedCount: Int { plan.selectedEntries.count }
    private var deselectedCount: Int { readyEntries.count - selectedCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 520, idealHeight: 640)
        .alert("Discard this batch?", isPresented: $showDiscardConfirm) {
            Button("Discard", role: .destructive) { discard() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The prepared companions in the buffer are deleted. Nothing in the catalog or the archive changes — the Angel can run again later.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recommended To Be Archived")
                    .font(.system(size: 16, weight: .semibold))
                Text("Considered \(plan.consideredCount) · prepared \(plan.entries.count) of \(plan.requestedCount) requested · \(Self.dateText(plan.createdAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !readyEntries.isEmpty, !isPromoting, !isDone {
                Button("Select all") { setAll(true) }
                Button("Select none") { setAll(false) }
            }
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Rows

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleEntries) { entry in
                    row(entry)
                    Divider()
                }
                if !settledEntries.isEmpty {
                    settledLine
                }
                if plan.entries.isEmpty {
                    Text("The Angel found nothing to recommend. \(rejectedLine)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(16)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: ArchiveAngelPlan.Entry) -> some View {
        let idx = plan.entries.firstIndex(where: { $0.id == entry.id })
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                if entry.status == .ready, let idx {
                    Toggle("", isOn: $plan.entries[idx].selected)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .disabled(isPromoting || isDone)
                } else {
                    Image(systemName: entry.status == .promoted ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .foregroundStyle(entry.status == .promoted ? Color.green : Color.red)
                        .frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(entry.filename)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(Self.durationText(entry.durationSeconds)) · \(MediaBytes.display(entry.sizeBytes))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        ArchiveAngelRowActions(entry: entry, beforeNavigate: { keepAndClose() })
                        scoreBadge(entry.score)
                    }
                    if let failure = entry.failure {
                        Text(failure)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let rel = entry.promotedRelPath {
                        Text("→ \(rel)")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.green)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    companionChips(entry)
                    if entry.status == .ready, let idx {
                        editors(idx, entry: entry)
                    }
                    whyDisclosure(entry)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(entry.status == .failed ? Color.red.opacity(0.06) : Color.clear)
        .opacity(entry.status == .ready && !entry.selected ? 0.55 : 1)
    }

    /// "5 promoted · 1 failed — Show" under the ready rows.
    private var settledLine: some View {
        let promoted = settledEntries.filter { $0.status == .promoted }.count
        let failed = settledEntries.filter { $0.status == .failed }.count
        let other = settledEntries.count - promoted - failed
        var parts: [String] = []
        if promoted > 0 { parts.append("\(promoted) already promoted") }
        if failed > 0 { parts.append("\(failed) failed") }
        if other > 0 { parts.append("\(other) still preparing") }
        return HStack(spacing: 6) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(.secondary)
            Text(parts.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button(showSettled ? "Hide" : "Show") { showSettled.toggle() }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .accessibilityIdentifier("archiveAngel.showSettled")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func scoreBadge(_ score: Int) -> some View {
        Text("\(score)")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.18)))
            .help("Evidence points — the number only orders the list; the Why lines are the reasons.")
    }

    private func companionChips(_ entry: ArchiveAngelPlan.Entry) -> some View {
        HStack(spacing: 6) {
            chip("Original", state: .done, note: "Copied source → archive at Promote; never buffered")
            ForEach(entry.steps) { step in
                chip(step.kind.label, state: step.state, note: step.note)
            }
            if entry.isOriginalOnly {
                Text("original only")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.orange)
            }
        }
    }

    private func chip(_ label: String, state: ArchiveAngelPlan.StepState, note: String) -> some View {
        let color: Color = {
            switch state {
            case .done: return .green
            case .skipped: return .secondary
            case .failed: return .red
            case .pending: return .yellow
            }
        }()
        let symbol: String = {
            switch state {
            case .done: return "checkmark.circle.fill"
            case .skipped: return "minus.circle"
            case .failed: return "xmark.circle.fill"
            case .pending: return "clock"
            }
        }()
        return HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(label).font(.system(size: 10))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
        .help(note.isEmpty ? label : "\(label): \(note)")
    }

    private func editors(_ idx: Int, entry: ArchiveAngelPlan.Entry) -> some View {
        let ext = (entry.filename as NSString).pathExtension
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("archive name")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .trailing)
                TextField("stem", text: stemBinding(idx, ext: ext))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: 320)
                    .disabled(isPromoting || isDone)
                if !ext.isEmpty {
                    Text(".\(ext.lowercased())")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text("date")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("YYYY-MM-DD or YYYY", text: dateBinding(idx))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: 150)
                    .disabled(isPromoting || isDone)
                Text(dateGuidance(entry.proposedDate))
                    .font(.system(size: 10))
                    .foregroundStyle(ArchiveAngelPromoter.dateHint(from: entry.proposedDate) == nil
                                     && !(entry.proposedDate ?? "").isEmpty ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Text("notes")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .trailing)
                TextField("optional — appended to the record's notes", text: $plan.entries[idx].userNotes)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .disabled(isPromoting || isDone)
            }
        }
    }

    private func whyDisclosure(_ entry: ArchiveAngelPlan.Entry) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedWhy.contains(entry.id) },
            set: { if $0 { expandedWhy.insert(entry.id) } else { expandedWhy.remove(entry.id) } }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(entry.evidence.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 6) {
                        Text(line.line).font(.system(size: 11))
                        Text("+\(line.points)")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 4)
            .padding(.top, 2)
        } label: {
            Text(entry.evidence.first?.line ?? "Why")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: Footer

    private var rejectedLine: String {
        plan.rejectedTotal == 0 ? "" : "\(plan.rejectedTotal) rejected as junk or ineligible."
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(readyEntries.count) recommended · \(deselectedCount) deselected · \(MediaBytes.display(plan.bytesToCopy)) to copy")
                    .font(.system(size: 12))
                if plan.rejectedTotal > 0 {
                    Text("· \(plan.rejectedTotal) rejected")
                        .font(.system(size: 12))
                    Button(showRejected ? "Hide" : "Show") { showRejected.toggle() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
                if plan.overflow > 0 {
                    Text("· \(plan.overflow) more would qualify")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if showRejected {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(plan.rejected.sorted { $0.value > $1.value }, id: \.key) { reason, n in
                        Text("\(n) · \(reason)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 8)
            }
            if let report = plan.report {
                Text(report.summary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(report.failed.isEmpty ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isPromoting, let job = promoter.job {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(job.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            HStack {
                if !isDone && !isPromoting {
                    Button("Discard batch…", role: .destructive) { showDiscardConfirm = true }
                        .disabled(model.isReadOnly)
                }
                Spacer()
                if isDone {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    // Rick 2026-09-09: "Cancel makes me feel like it might
                    // undo what just happened" — it never did; it is Close.
                    Button("Close") { keepAndClose() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isPromoting)
                        .help("Closes the sheet and keeps the batch — nothing is undone. The remaining rows stay ready under the Archive tab.")
                    if selectedCount == 0 && !isPromoting {
                        // A greyed "Promote 0" after a promote reads as stuck.
                        Button("Done") { keepAndClose() }
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("archiveAngel.done")
                    } else {
                        Button("Promote \(selectedCount)") { promote() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.isReadOnly || isPromoting)
                            .accessibilityIdentifier("archiveAngel.promote")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Actions

    private func setAll(_ on: Bool) {
        for i in plan.entries.indices where plan.entries[i].status == .ready {
            plan.entries[i].selected = on
        }
    }

    private func keepAndClose() {
        try? ArchiveAngelPlanStore.save(plan)
        dismiss()
    }

    private func discard() {
        plan.status = .discarded
        plan.log.append("Discarded by the user")
        try? ArchiveAngelPlanStore.save(plan)   // the decision is durable even if removal fails
        do {
            try ArchiveAngelPlanStore.removeBatchFolder(plan)
        } catch {
            model.log("Archive Angel: could not remove the buffer folder — \(error.localizedDescription)")
        }
        model.log("Archive Angel: batch \(Self.dateText(plan.createdAt)) discarded")
        dismiss()
    }

    private func promote() {
        for i in plan.entries.indices where plan.entries[i].status == .ready && plan.entries[i].selected {
            let note = plan.entries[i].userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty, let rec = model.record(forID: plan.entries[i].id) {
                rec.userNotes = rec.userNotes.isEmpty ? note : rec.userNotes + "\n" + note
            }
        }
        var working = plan
        let job = promoter.promote(plan: &working, model: model, center: fileOpsCenter) { settled in
            plan = settled
        }
        plan = working
        if job == nil {
            model.log("Archive Angel: nothing was started — " + (working.log.last ?? "see the batch log"))
        }
    }

    // MARK: Bindings + text

    private func stemBinding(_ idx: Int, ext: String) -> Binding<String> {
        Binding(
            get: { (plan.entries[idx].proposedName as NSString).deletingPathExtension },
            set: { newStem in
                let cleaned = newStem.replacingOccurrences(of: "/", with: "-")
                plan.entries[idx].proposedName = ext.isEmpty ? cleaned : "\(cleaned).\(ext)"
            })
    }

    private func dateBinding(_ idx: Int) -> Binding<String> {
        Binding(get: { plan.entries[idx].proposedDate ?? "" },
                set: { plan.entries[idx].proposedDate = $0.isEmpty ? nil : $0 })
    }

    private func dateGuidance(_ typed: String?) -> String {
        guard let typed, !typed.isEmpty else { return "undated → Undated folder" }
        guard let hint = ArchiveAngelPromoter.dateHint(from: typed) else { return "not a date I understand" }
        return "→ \(hint.filenamePrefix)"
    }

    static func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    static func durationText(_ s: Double) -> String { ArchiveAngelScorer.durationText(s) }
}
