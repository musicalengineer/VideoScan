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
        .onAppear {
            // Rows follow catalog renames (Rick 2026-09-10): Show in
            // Catalog → rename → back here shows the new name.
            if !ArchiveAngelPromoter.followRenames(plan: &plan, model: model).isEmpty {
                ArchiveAngelPlanStore.saveLogged(plan, context: "review/promote")
            }
        }
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
                    // A row the USER skipped is not a casualty — grey
                    // turn-arrow, never the red octagon of a failure
                    // (Rick 2026-09-13).
                    Image(systemName: Self.settledSymbol(entry.status))
                        .foregroundStyle(Self.settledColor(entry.status))
                        .frame(width: 16)
                        .help(entry.skipNote ?? entry.failure ?? entry.status.rawValue)
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
                    if entry.status == .skipped, let skipNote = entry.skipNote {
                        Text(skipNote)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
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

    /// "5 promoted · 3 skipped · 1 failed — Show" under the ready rows.
    private var settledLine: some View {
        let promoted = settledEntries.filter { $0.status == .promoted }.count
        let failed = settledEntries.filter { $0.status == .failed }.count
        let skipped = settledEntries.filter { $0.status == .skipped }.count
        let other = settledEntries.count - promoted - failed - skipped
        var parts: [String] = []
        if promoted > 0 { parts.append("\(promoted) already promoted") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
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

    /// Icon/colour for a row that is no longer awaiting a decision.
    static func settledSymbol(_ status: ArchiveAngelPlan.EntryStatus) -> String {
        switch status {
        case .promoted: return "checkmark.seal.fill"
        case .skipped: return "arrow.uturn.forward.circle"
        default: return "xmark.octagon.fill"
        }
    }

    static func settledColor(_ status: ArchiveAngelPlan.EntryStatus) -> Color {
        switch status {
        case .promoted: return .green
        case .skipped: return .secondary
        default: return .red
        }
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
                    // Never modal over a running promote (Rick 2026-09-20):
                    // the job lives in Media File Operations; Close only
                    // closes the sheet.
                    Button("Close") { keepAndClose() }
                        .keyboardShortcut(.cancelAction)
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
        ArchiveAngelPlanStore.saveLogged(plan, context: "review/promote")
        dismiss()
    }

    private func discard() {
        // ONE clear verb (curation Phase 2, 2026-09-19): the angelCleared
        // ledger lines for the undecided rows (half a skip), the plan saved
        // .discarded before anything is deleted, the catalogued companions
        // retired (codex #1572), the folder removed, the log line.
        let outcome = model.clearArchiveAngelBatch(plan, reason: "discarded by you in the review sheet")
        // `cleared`, not `refusal == nil`: a failed plan save is an error
        // with no refusal, and the sheet's copy must not claim a decision
        // that did not persist (codex review 2026-09-20 #2).
        if outcome.cleared { plan.status = .discarded }
        dismiss()
    }

    private func promote() {
        for i in plan.entries.indices where plan.entries[i].status == .ready && plan.entries[i].selected {
            let note = plan.entries[i].userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty, let rec = model.record(forID: plan.entries[i].id) {
                // Idempotent (audit P2): a retry after "nothing to promote"
                // used to append the same note again.
                let merged = Self.mergedNotes(existing: rec.userNotes, adding: note)
                if merged != rec.userNotes {
                    rec.userNotes = merged
                    let line = "Archive Angel: review note carried to \(rec.filename)'s catalog notes"
                    model.log(line); appLog.write(line)
                }
            }
        }
        // Phase 1 attention memory: a ready row left unchecked at Promote
        // is a pass on it, the same as Skip — noted ONCE per batch and row.
        Self.noteUncheckedAtPromote(plan: &plan, model: model)
        var working = plan
        let job = promoter.promote(plan: &working, model: model, center: fileOpsCenter) { settled in
            plan = settled
        }
        plan = working
        if job == nil {
            model.log("Archive Angel: nothing was started — " + (working.log.last ?? "see the batch log"))
            return
        }
        // Rick 2026-09-20: "while a promotion is ongoing, the app is locked
        // up in a modal block … there should be a way for this to be in
        // the MFO window." The promote IS an MFO job; the promoter saves
        // the plan at every step and the model offers "Archived — what
        // next?" when it lands, so this sheet has no job left here.
        model.log("Archive Angel: Promote is running in Media File Operations — closing the review; "
                  + "the batch returns to the Archive tab when it lands")
        dismiss()
    }

    /// The unchecked-at-Promote pass, idempotent per (batch, row): every
    /// ready row that is not selected AND has no `uncheckedNotedAt` yet
    /// gets one `angelSkipped` ledger line (reason "unchecked") and the
    /// stamp; the plan is saved so the stamp outlives this sheet. A
    /// retried Promote (identity refused, nothing to promote, a failed
    /// job) finds the stamp and emits nothing (codex 2026-09-20 #7).
    /// Returns the ids noted this time. Main actor; the production path.
    @MainActor
    @discardableResult
    static func noteUncheckedAtPromote(plan: inout ArchiveAngelPlan, model: VideoScanModel,
                                       at now: Date = Date()) -> [UUID] {
        var noted: [UUID] = []
        for i in plan.entries.indices
        where plan.entries[i].status == .ready && !plan.entries[i].selected && plan.entries[i].uncheckedNotedAt == nil {
            plan.entries[i].uncheckedNotedAt = now
            noted.append(plan.entries[i].id)
        }
        guard !noted.isEmpty else { return [] }
        model.ledgerAngelAttention(.angelSkipped, recordIDs: noted, batchID: plan.batchID, reason: "unchecked", at: now)
        ArchiveAngelPlanStore.saveLogged(plan, context: "review/promote (unchecked noted)")
        return noted
    }

    /// The catalog notes with `adding` appended once — never a second time.
    /// Line-exact (codex #1572): "Grandma birthday" inside "Not Grandma
    /// birthday" is a different note and must still be added.
    static func mergedNotes(existing: String, adding: String) -> String {
        let add = adding.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !add.isEmpty else { return existing }
        let lines = existing.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(add) { return existing }
        return existing.isEmpty ? add : existing + "\n" + add
    }

    // MARK: Bindings + text

    private func stemBinding(_ idx: Int, ext: String) -> Binding<String> {
        Binding(
            get: { (plan.entries[idx].proposedName as NSString).deletingPathExtension },
            set: { newStem in
                let cleaned = newStem.replacingOccurrences(of: "/", with: "-")
                plan.entries[idx].proposedName = ext.isEmpty ? cleaned : "\(cleaned).\(ext)"
                plan.entries[idx].userEditedName = true
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
