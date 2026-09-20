// ArchivedWhatNextSheet.swift
// "Archived — what next?" (promote-and-prune stage 2, Rick 2026-09-12,
// docs/promote_and_prune_workflow_design.md §"The sheet").
//
// Appears once per Promote batch, only when every copy landed verified
// (never mid-batch, never on a failed file), and from Tidy → "Copies of
// archived media" for the backlog. Shows: the summary line, the
// protection line, the 3-2-1 tip, the attestation controls (cloud /
// off-site, each yes-with-label / no / n-a, scope this batch vs only
// ★★★), and the CHECKLIST.
//
// 2026-09-20, Rick: "the follow-up dialog about deleting dups did not let
// me delete any dups … I want to see a list of dups and decide which ones
// to delete, maybe leave one behind, maybe not." The 9/12 design let the
// bar GATE deletion — a ★★★ family with no cloud copy attested hid its
// three working copies behind "Not now". Now the bar ADVISES and the
// person decides: one row per copy of every family in the batch, a
// checkbox on each candidate (disabled with the reason on the archive
// copy, anything inside the Master Archive, a version, a copy with a
// note, an offline copy, a recovered A/V pair member), the family's
// advice in orange when the bar is not met. The bar-respecting plan is
// the DEFAULT set of checks; "Keep one working copy" + the volume picker
// set that default (toggling them resets the checks); a manual check
// after that wins. The attestation radios still recompute the advice.
// The footer says "Move N to Trash — X GB", enabled iff N > 0; the
// confirmation names the count and bytes, says in words when the choice
// goes against the bar, and when a file will exist only in the Master
// Archive afterwards.
//
// Apply → `applyPrune(shown:selected:…)` (fresh plan + on-disk safety in
// front of the ONE existing Trash routine) → the result replaces the
// caption. "Not now" dismisses. Attestation choices DO persist — they are
// stage 1's `recordAttestation` (catalog record + attestation journal)
// and write a ledger `attestation` line.
//
// Body discipline: every section is its own small view/builder (giant
// SwiftUI bodies fail on the CI runner); the plan is computed off-main by
// the model (`prunePlan(for:options:)`), never in the body; the row list
// is derived from the plan VALUE once per reload (O(rows in the batch's
// families), capped at 200 rows shown), never from `records`.
//
// (For Rick: `@State` ≈ a member the view owns and re-renders on change;
// a `Binding` ≈ a getter/setter pair handed to a child control.)

import SwiftUI
import VideoScanCore

struct ArchivedWhatNextSheet: View {
    @EnvironmentObject private var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss

    let request: ArchivedWhatNextRequest

    // Attestation state (seeded from the batch's current answers).
    @State private var cloudAnswer: BackupAttestation.Answer?
    @State private var cloudLabel = ""
    @State private var offsiteAnswer: BackupAttestation.Answer?
    @State private var offsiteLabel = ""
    @State private var onlyImportant = false

    // Plan state.
    @State private var keepOne = true
    @State private var keeperVolume: String?
    @State private var plan: PrunePlan?
    @State private var protection: ProtectionSummary
    /// Bumped whenever an input the plan depends on changes.
    @State private var planRevision = 0

    // The checklist (2026-09-20).
    /// Copy record ids the person checked. Seeded from the plan's default
    /// (what the bar-respecting plan would Trash); reset by the keep-one
    /// helper; a manual check after that wins across plan reloads.
    @State private var selected: Set<UUID> = []
    @State private var selectionTouched = false
    @State private var checklist = PruneChecklist.empty
    @State private var summary = PrunePlan.Selection.empty
    /// A plan reload is in flight: the list, the count and the
    /// confirmation are stale until it lands, so Apply waits (QA MINOR).
    @State private var reloading = false

    // Apply (2026-09-19).
    @State private var confirmingApply = false
    @State private var applying = false
    @State private var applied: VideoScanModel.PruneApplyOutcome?

    init(request: ArchivedWhatNextRequest) {
        self.request = request
        _protection = State(initialValue: request.protection)
        if case .answer(let a, let label) = request.protection.cloud {
            _cloudAnswer = State(initialValue: a); _cloudLabel = State(initialValue: label ?? "")
        }
        if case .answer(let a, let label) = request.protection.offsite {
            _offsiteAnswer = State(initialValue: a); _offsiteLabel = State(initialValue: label ?? "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            protectionSection
            attestationSection
            planSection
            footer
        }
        .padding(20)
        .frame(width: 680)
        .task(id: planRevision) { await reloadPlan() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 26))
                .foregroundColor(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("whatNext.headline")
                Text("Archived — what next?")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var headline: String {
        let n = request.fileCount
        let size = MediaBytes.display(request.totalBytes)
        switch request.source {
        case .promoteBatch:
            return "\(n) file\(n == 1 ? "" : "s") (\(size)) \(n == 1 ? "is" : "are") in the Master Archive on \(request.archiveLabel), every copy read back and verified."
        case .tidyBacklog:
            return "\(n) cop\(n == 1 ? "y" : "ies") (\(size)) outside the Master Archive already \(n == 1 ? "has" : "have") a verified archive copy."
        }
    }

    // MARK: Protection

    private var protectionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Text("Protection now:")
                    .font(.system(size: 12, weight: .semibold))
                Text(protection.displayLine)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("whatNext.protectionLine")
            }
            Text("3-2-1 tip: one more device and one copy elsewhere keeps a fire or a failed RAID from taking everything. Nothing here deletes the archive copy.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Attestations

    private var attestationSection: some View {
        GroupBox("I also have these files…") {
            VStack(alignment: .leading, spacing: 8) {
                AttestationAnswerRow(kind: .cloud, answer: $cloudAnswer, label: $cloudLabel,
                                     placeholder: "in: iCloud, Backblaze…", onCommit: { apply(.cloud) })
                AttestationAnswerRow(kind: .offsite, answer: $offsiteAnswer, label: $offsiteLabel,
                                     placeholder: "at: Tim's house…", onCommit: { apply(.offsite) })
                Picker("Applies to:", selection: $onlyImportant) {
                    Text("this batch").tag(false)
                    Text("only the ★★★ ones").tag(true)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .font(.system(size: 11))
                Text("Your word is remembered on each file (and in the archive's manifest). VideoScan never checks a cloud or off-site copy.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    /// The ids the attestation applies to (this batch, or only ★★★).
    private var attestationTargets: [UUID] {
        guard onlyImportant else { return request.recordIDs }
        return request.recordIDs.filter { (model.record(forID: $0)?.starRating ?? 0) >= 3 }
    }

    /// Persist one kind's answer (stage 1's recordAttestation → catalog +
    /// attestation journal + ledger line), then recompute the plan — the
    /// advice and the default checks depend on it.
    private func apply(_ kind: BackupAttestation.Kind) {
        let answer: BackupAttestation.Answer?
        let label: String
        switch kind {
        case .cloud:   answer = cloudAnswer;   label = cloudLabel
        case .offsite: answer = offsiteAnswer; label = offsiteLabel
        case .drive:   return
        }
        guard let answer else { return }
        let ids = attestationTargets
        guard !ids.isEmpty else { return }
        model.recordAttestation(kind: kind, answer: answer, label: answer == .yes ? label : nil,
                                for: ids, batchID: request.batchID)
        planRevision &+= 1
    }

    // MARK: Plan

    @ViewBuilder
    private var planSection: some View {
        if let plan {
            PruneChecklistSection(plan: plan, checklist: checklist, selected: selected, summary: summary,
                                  keepOne: $keepOne, keeperVolume: $keeperVolume,
                                  onDefaultsChanged: {
                                      // The helper sets the DEFAULT checks: reset to the plan's.
                                      selectionTouched = false
                                      planRevision &+= 1
                                  },
                                  onCheck: { id, on in setChecked(id, on) })
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Working out the copies…")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
        }
    }

    private func reloadPlan() async {
        reloading = true
        defer { reloading = false }
        let options = PrunePlan.Options(keepOne: keepOne, keeperVolume: keeperVolume, bar: model.importanceBar)
        let ids = request.recordIDs
        async let computed = model.prunePlan(for: ids, options: options)
        async let fresh = model.batchProtection(for: ids)
        let (p, prot) = await (computed, fresh)
        guard !Task.isCancelled else { return }
        plan = p
        protection = prot
        let list = PruneChecklist.build(p)
        checklist = list
        // Manual checks survive a reload (minus anything no longer
        // checkable); otherwise the plan's default is the selection. Only
        // LISTED rows may be selected — nothing the person cannot see and
        // uncheck is ever counted or moved.
        selected = (selectionTouched ? selected.intersection(p.checkableIDs) : p.defaultSelection)
            .intersection(list.visibleIDs)
        summary = p.selection(selected)
    }

    private func setChecked(_ id: UUID, _ on: Bool) {
        guard let plan else { return }
        if on { selected.insert(id) } else { selected.remove(id) }
        selectionTouched = true
        summary = plan.selection(selected)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Spacer()
                Button(applied == nil ? "Not now" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("whatNext.notNow")
                if applying { ProgressView().controlSize(.small) }
                Button(applyTitle) { confirmingApply = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!Self.canApply(selectedCount: summary.count, applying: applying,
                                             applied: applied != nil, readOnly: model.isReadOnly,
                                             reloading: reloading))
                    .accessibilityIdentifier("whatNext.apply")
            }
            if let applied {
                Text(applied.summary + ".")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(applied.failed.isEmpty && applied.held.isEmpty ? .secondary : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("whatNext.applyResult")
            } else {
                Text("The archive copy and every copy you leave unchecked are never touched. Everything moved can be restored from the Trash.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("whatNext.applyCaption")
            }
        }
        .confirmationDialog(confirmTitle, isPresented: $confirmingApply) {
            Button("Move to Trash") { runApply() }
                .accessibilityIdentifier("whatNext.confirmApply")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.confirmMessage(summary))
        }
    }

    /// Apply acts only on a non-empty selection, once, and never while
    /// the plan it would act on is being recomputed.
    static func canApply(selectedCount: Int, applying: Bool, applied: Bool, readOnly: Bool,
                         reloading: Bool = false) -> Bool {
        selectedCount > 0 && !applying && !applied && !readOnly && !reloading
    }

    private var confirmTitle: String {
        let n = summary.count
        return "Move \(n) cop\(n == 1 ? "y" : "ies") (\(MediaBytes.display(summary.bytes))) to the Trash?"
    }

    /// The confirmation's body: what stays, then — in words — what goes
    /// against the bar and which files will then exist only in the
    /// Master Archive.
    static func confirmMessage(_ s: PrunePlan.Selection) -> String {
        var lines = ["The archive copy and every copy you left unchecked stay. Anything that changed since this list was worked out is held back, and everything moved can be restored from the Trash."]
        if let against = s.overrideSentence { lines.append(against) }
        if let only = s.archiveOnlySentence { lines.append(only) }
        return lines.joined(separator: "\n\n")
    }

    private func runApply() {
        guard let shown = plan, !reloading else { return }
        let options = PrunePlan.Options(keepOne: keepOne, keeperVolume: keeperVolume, bar: model.importanceBar)
        applying = true
        Task {
            let outcome = await model.applyPrune(shown: shown, selected: selected, recordIDs: request.recordIDs,
                                                 options: options, batchID: request.batchID)
            applied = outcome
            applying = false
            selectionTouched = false
            planRevision &+= 1   // the plan now reflects what is left
        }
    }

    private var applyTitle: String {
        let n = summary.count
        return n == 0 ? "Move to Trash" : "Move \(n) to Trash — \(MediaBytes.display(summary.bytes))"
    }
}

// MARK: - One attestation row (yes-with-label / no / n-a)

struct AttestationAnswerRow: View {
    let kind: BackupAttestation.Kind
    @Binding var answer: BackupAttestation.Answer?
    @Binding var label: String
    let placeholder: String
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(kind.displayName):")
                .font(.system(size: 12))
                .frame(width: 60, alignment: .trailing)
            Picker("", selection: $answer) {
                Text("yes").tag(BackupAttestation.Answer?.some(.yes))
                Text("no").tag(BackupAttestation.Answer?.some(.no))
                Text("n/a for these").tag(BackupAttestation.Answer?.some(.notApplicable))
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()
            .font(.system(size: 11))
            .onChange(of: answer) { onCommit() }
            .accessibilityIdentifier("whatNext.attest.\(kind.rawValue)")
            if answer == .yes {
                TextField(placeholder, text: $label)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(maxWidth: 200)
                    .onSubmit(onCommit)
                    .accessibilityIdentifier("whatNext.attest.\(kind.rawValue).label")
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - The checklist, as a flat list the view can walk

/// The sheet's rows, derived ONCE from the plan value per reload (never in
/// a body): a header per family, then its copies. Families with a
/// default check are ALWAYS listed in full, first — a copy that would go
/// must be visible and uncheckable-by-hand (QA 2026-09-20, MAJOR 3: the
/// Tidy backlog is routinely > 200 rows); the remaining families fill up
/// to `maxRows` copy rows, the rest counted as "… and N more". Pure;
/// tests pin the cap and that no default check is ever hidden.
struct PruneChecklist: Equatable {
    struct Item: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Family header: display name, level, advice (nil = covered).
            case family(name: String, key: String, level: String, advice: String?)
            case copy(PrunePlan.CopyRow)
        }
        let id: String
        let kind: Kind
    }

    static let maxRows = 200
    static let empty = PruneChecklist(items: [], visibleIDs: [], hiddenRowCount: 0)

    let items: [Item]
    /// The copy rows listed — the only ids a selection may hold.
    let visibleIDs: Set<UUID>
    /// Copy rows not listed because of the cap (never a default check).
    let hiddenRowCount: Int

    static func build(_ plan: PrunePlan, maxRows: Int = maxRows) -> PruneChecklist {
        var items: [Item] = []
        var visible = Set<UUID>()
        items.reserveCapacity(min(plan.rowCount, maxRows) + plan.families.count)
        // `budget` is spent only by the capped (no-default-check) families,
        // so a big default set never starves them of their 200 rows.
        var budget = maxRows, hidden = 0
        func list(_ i: Int, _ family: PrunePlan.Family, capped: Bool) {
            if capped, budget <= 0 { hidden += family.rows.count; return }
            let key = family.key.isEmpty ? family.displayName : family.key
            items.append(Item(id: "f\(i)", kind: .family(name: family.displayName, key: key,
                                                          level: family.level.displayName, advice: family.advice)))
            for row in family.rows {
                if capped {
                    if budget <= 0 { hidden += 1; continue }
                    budget -= 1
                }
                items.append(Item(id: row.id.uuidString, kind: .copy(row)))
                visible.insert(row.id)
            }
        }
        let hasDefault = plan.families.map { $0.rows.contains(where: \.defaultChecked) }
        for (i, family) in plan.families.enumerated() where hasDefault[i] { list(i, family, capped: false) }
        for (i, family) in plan.families.enumerated() where !hasDefault[i] { list(i, family, capped: true) }
        return PruneChecklist(items: items, visibleIDs: visible, hiddenRowCount: hidden)
    }
}

// MARK: - The checklist section

struct PruneChecklistSection: View {
    let plan: PrunePlan
    let checklist: PruneChecklist
    let selected: Set<UUID>
    let summary: PrunePlan.Selection
    @Binding var keepOne: Bool
    @Binding var keeperVolume: String?
    /// The keep-one helper changed: recompute the DEFAULT checks.
    let onDefaultsChanged: () -> Void
    let onCheck: (UUID, Bool) -> Void

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                keeperRow
                if plan.rowCount > 0 { list }
                summaryRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var title: String {
        let n = plan.extraCount
        return n == 0
            ? "No extra copies outside the archive"
            : "Choose what goes — \(n) extra cop\(n == 1 ? "y" : "ies") (\(MediaBytes.display(plan.extraBytes))) outside the archive"
    }

    private var keeperRow: some View {
        HStack(spacing: 8) {
            Toggle("Keep one working copy", isOn: $keepOne)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .onChange(of: keepOne) { onDefaultsChanged() }
                .accessibilityIdentifier("whatNext.keepOne")
            Text("on:")
                .font(.system(size: 12))
            Picker("", selection: $keeperVolume) {
                Text(plan.suggestedKeeperVolume.map { "Automatic (\($0))" } ?? "Automatic").tag(String?.none)
                ForEach(plan.keeperVolumes) { v in
                    Text(volumeLabel(v)).tag(String?.some(v.name))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240)
            .font(.system(size: 12))
            .onChange(of: keeperVolume) { onDefaultsChanged() }
            .accessibilityIdentifier("whatNext.keeperVolume")
            Text(plan.keeperRequiredCount > 0
                 ? "(sets the default checks; required for \(plan.keeperRequiredCount) ★★/★★★ file\(plan.keeperRequiredCount == 1 ? "" : "s"))"
                 : "(sets the default checks)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func volumeLabel(_ v: PrunePlan.VolumeChoice) -> String {
        guard let free = v.freeBytes else { return v.name }
        return "\(v.name) — \(MediaBytes.display(free)) free"
    }

    private var list: some View {
        ScrollView {
            // Lazy: every family with a default check is listed in full,
            // so a big Tidy backlog can be thousands of rows.
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(checklist.items) { item in
                    switch item.kind {
                    case .family(let name, let key, let level, let advice):
                        familyHeader(name: name, key: key, level: level, advice: advice)
                    case .copy(let row):
                        copyRow(row)
                    }
                }
                if checklist.hiddenRowCount > 0 {
                    Text("… and \(checklist.hiddenRowCount) more (none checked; nothing unlisted is ever moved)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("whatNext.moreRows")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 60, maxHeight: 260)
    }

    private func familyHeader(name: String, key: String, level: String, advice: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("· \(level)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            if let advice {
                Text(advice)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("whatNext.family.\(key).advice")
            }
        }
        .padding(.top, 6)
    }

    private func copyRow(_ row: PrunePlan.CopyRow) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(get: { selected.contains(row.id) }, set: { onCheck(row.id, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!row.checkable)
                .accessibilityIdentifier("whatNext.copy.\(row.id.uuidString).check")
            Text(row.copy.volumeName.isEmpty ? "—" : row.copy.volumeName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)
            Text(row.copy.filename)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(row.checkable ? .primary : .secondary)
            Spacer(minLength: 4)
            if let reason = row.reasonText {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Text(MediaBytes.display(row.copy.sizeBytes))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.leading, 12)
    }

    @ViewBuilder
    private var summaryRow: some View {
        let n = summary.count
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .foregroundColor(n == 0 ? .secondary : .orange)
                Text(n == 0
                     ? "Nothing checked — nothing goes to the Trash."
                     : "\(n) checked — \(MediaBytes.display(summary.bytes)) to the Trash")
                    .font(.system(size: 12))
                    .accessibilityIdentifier("whatNext.trashLine")
                if let against = summary.overrideSentence {
                    Text(against)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if plan.notCoveredCount > 0 {
                Text("\(plan.notCoveredCount) file\(plan.notCoveredCount == 1 ? " is" : "s are") not covered by the bar you set — the advice is under each. You decide.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("whatNext.notCoveredLine")
            }
        }
    }
}
