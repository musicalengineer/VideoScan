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
// bar GATE deletion; now the bar ADVISES and the person decides.
//
// v3, later the same day, after using it: "It wouldn't let me delete as
// freely as I would have liked … a bigger dialog box, and allow me to
// delete any copy or all copies on any drive EXCEPT FamilyArchive …
// many are subsets or improvements or trimmed … don't even list that as
// an option. It would not let me select M4drive at all." And: "I would
// rather you be cautious with my family media than rampantly allowing me
// to delete." So, per family:
//   * the header says "✓ In FamilyArchive, verified (N files)" — the
//     archive copies are never rows;
//   * one row per WORKING copy: checkbox · volume · path · size · kind
//     chip (original / duplicate / balanced / trimmed / transcoded /
//     cleaned / other version) · advice. Versions and copies with a note
//     are checkable (unchecked by default, the advice says why); only an
//     offline copy, an A/V pair half, and every row of a family whose
//     archive copy is not verified are disabled, with the reason;
//   * "Might be copies": name-related records on working volumes that are
//     NOT in the family by content — "Hash to confirm" (per row, or all)
//     computes the segmented hash off-main and re-plans; a match joins the
//     family as a normal row, a mismatch reads "different footage";
//   * "Select all deletable" / "Select none" per family and for the batch;
//   * a MISSING FILE (2026-09-21 — Rick: "'M4drive' was said 'not
//     connected' in some cases which is weird"; the boot volume is M4drive
//     and the file had been moved or deleted outside the app) is listed,
//     disabled, "not on M4drive any more (moved or deleted?)", with an
//     inline "Remove from catalog" (and "Remove N missing rows" on the
//     family header when there are several) — the existing purge
//     tombstone, nothing on disk — after which the plan reloads.
// The attestation "n/a for these" satisfies the bar's cloud-or-off-site
// want for this batch (the ledger still records n/a). The sheet is
// 960×720 and resizable. The plan is logged, one line per family, when
// it is first shown (and after each hash-to-confirm re-plan).
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
// families), capped at 200 rows for families with no default check),
// never from `records`.
//
// (For Rick: `@State` ≈ a member the view owns and re-renders on change;
// a `Binding` ≈ a getter/setter pair handed to a child control.)

import SwiftUI
import VideoScanCore

struct ArchivedWhatNextSheet: View {
    @EnvironmentObject private var model: VideoScanModel
    @EnvironmentObject private var fileOpsCenter: MediaFileOperationsCenter
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
    /// The first plan (and every re-plan after a hash) is logged, one
    /// line per family.
    @State private var logPlan = true

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
    /// Records a hash-to-confirm is running for (buttons show a spinner).
    @State private var hashing: Set<UUID> = []

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
        VStack(alignment: .leading, spacing: 12) {
            header
            protectionSection
            attestationSection
            planSection
                .frame(maxHeight: .infinity)
            footer
        }
        .padding(20)
        .frame(minWidth: 960, idealWidth: 960, maxWidth: .infinity,
               minHeight: 720, idealHeight: 720, maxHeight: .infinity)
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
                Text("Archived — what next? Every copy below is outside \(request.archiveLabel); nothing here ever touches the archive.")
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
            Text("3-2-1 tip: one more device and one copy elsewhere keeps a fire or a failed RAID from taking everything. The bar you set advises; you decide.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Attestations

    private var attestationSection: some View {
        GroupBox("I also have these files…") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 24) {
                    AttestationAnswerRow(kind: .cloud, answer: $cloudAnswer, label: $cloudLabel,
                                         placeholder: "in: iCloud, Backblaze…", onCommit: { apply(.cloud) })
                    AttestationAnswerRow(kind: .offsite, answer: $offsiteAnswer, label: $offsiteLabel,
                                         placeholder: "at: Tim's house…", onCommit: { apply(.offsite) })
                }
                HStack(spacing: 10) {
                    Picker("Applies to:", selection: $onlyImportant) {
                        Text("this batch").tag(false)
                        Text("only the ★★★ ones").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .font(.system(size: 11))
                    Text("Your word is remembered on each file (and in the archive's manifest); \"n/a for these\" counts as met for this batch. VideoScan never checks a cloud or off-site copy.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
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
                                  hashing: hashing, archiveLabel: request.archiveLabel,
                                  keepOne: $keepOne, keeperVolume: $keeperVolume,
                                  onDefaultsChanged: {
                                      // The helper sets the DEFAULT checks: reset to the plan's.
                                      selectionTouched = false
                                      planRevision &+= 1
                                  },
                                  onCheck: { id, on in setChecked([id], on) },
                                  onSelect: { ids, on in setChecked(ids, on) },
                                  onHash: { ids in runHash(ids) },
                                  onRemoveMissing: { ids in removeMissing(ids) })
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
        if logPlan {
            logPlan = false
            model.logArchivedWhatNextPlan(p, batchID: request.batchID)
        }
    }

    private func setChecked(_ ids: [UUID], _ on: Bool) {
        guard let plan else { return }
        let allowed = plan.checkableIDs.intersection(checklist.visibleIDs)
        for id in ids where allowed.contains(id) {
            if on { selected.insert(id) } else { selected.remove(id) }
        }
        selectionTouched = true
        summary = plan.selection(selected)
    }

    /// "Hash to confirm": hash the records named (a related row plus the
    /// family members that have no hash), then re-plan; a matching hash
    /// joins the family on that reload.
    private func runHash(_ ids: [UUID]) {
        let fresh = ids.filter { !hashing.contains($0) }
        guard !fresh.isEmpty else { return }
        hashing.formUnion(fresh)
        Task {
            _ = await model.hashToConfirm(recordIDs: fresh)
            hashing.subtract(fresh)
            logPlan = true
            planRevision &+= 1
        }
    }

    /// "Remove from catalog" on a missing-file row (or "Remove N missing
    /// rows" on a family): tombstone the records — the file is not there,
    /// nothing on disk is touched — then re-plan and log the new plan.
    private func removeMissing(_ ids: [UUID]) {
        guard let plan else { return }
        let allowed = Set(plan.missingIDs)
        let targets = ids.filter { allowed.contains($0) }
        guard !targets.isEmpty else { return }
        Task {
            _ = await model.removeMissingCopiesFromCatalog(recordIDs: targets)
            logPlan = true
            planRevision &+= 1
        }
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
                Text("The originals in \(request.archiveLabel) and every copy you leave unchecked are never touched. A duplicate is read byte-for-byte against the archive before it goes; a version goes on its provenance. Everything moved can be restored from the Trash.")
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
            Text(Self.confirmMessage(summary, archiveLabel: request.archiveLabel))
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

    /// The confirmation's body: the counts, what stays, then — in words —
    /// what goes against the bar and which files will then exist only in
    /// the Master Archive.
    static func confirmMessage(_ s: PrunePlan.Selection, archiveLabel: String = "the Master Archive") -> String {
        let n = s.count
        var lines = ["\(n) cop\(n == 1 ? "y" : "ies") (\(MediaBytes.display(s.bytes))) go\(n == 1 ? "es" : "") to the Trash. The originals in \(archiveLabel) are untouched, and so is every copy you left unchecked. Anything that changed since this list was worked out is held back; everything moved can be restored from the Trash."]
        if let verify = s.verifySentence { lines.append(verify) }
        if let against = s.overrideSentence { lines.append(against) }
        if let only = s.archiveOnlySentence { lines.append(only) }
        return lines.joined(separator: "\n\n")
    }

    /// Hand the plan + the person's checks to a Media File Operation and
    /// close (Rick 2026-09-20: "the app blocks when post-promote delete of
    /// big files" — nothing long runs behind a modal). The job runs the
    /// same pipeline `applyPrune` runs, one file at a time, and names
    /// every held copy in its row and in the log.
    private func runApply() {
        guard let shown = plan, !reloading, !applying else { return }
        let options = PrunePlan.Options(keepOne: keepOne, keeperVolume: keeperVolume, bar: model.importanceBar)
        applying = true
        let n = summary.count
        let job = fileOpsCenter.startedByUser {
            $0.startPruneApply(shown: shown, selected: selected, recordIDs: request.recordIDs,
                               options: options, batchID: request.batchID, model: model)
        }
        // The center refuses a second batch while one runs (and a
        // read-only viewer): say so and stay open — nothing was started.
        if job.wasRefused {
            let why: String
            if case .failed(let message) = job.state { why = message } else { why = "refused" }
            model.log("Archived — what next?: not started — \(why)")
            applying = false
            return
        }
        model.log("Archived — what next?: Trashing \(n) cop\(n == 1 ? "y" : "ies") in Media File Operations — each is checked byte-for-byte against the archive first")
        dismiss()
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
                    .frame(maxWidth: 180)
                    .onSubmit(onCommit)
                    .accessibilityIdentifier("whatNext.attest.\(kind.rawValue).label")
            }
        }
    }
}

// MARK: - The checklist, as a flat list the view can walk

/// The sheet's rows, derived ONCE from the plan value per reload (never in
/// a body): a header per family, its working copies, then its "might be
/// copies". Families with a default check are ALWAYS listed in full,
/// first — a copy that would go must be visible and uncheckable-by-hand
/// (QA 2026-09-20, MAJOR 3: the Tidy backlog is routinely > 200 rows);
/// the remaining families fill up to `maxRows` copy rows, the rest counted
/// as "… and N more". Pure; tests pin the cap and that no default check
/// is ever hidden.
struct PruneChecklist: Equatable {
    /// The family header line: the archive side in words, the level, the
    /// advice (orange) and note (grey), and what the per-family buttons
    /// act on.
    struct FamilyHeader: Equatable {
        let name: String
        let key: String
        let level: String
        let advice: String?
        let note: String?
        let archiveCount: Int
        let archiveVerified: Bool
        /// Archive copies of VERSIONS in the family — a note, never proof.
        let versionArchiveCount: Int
        /// Every checkable row, in row order.
        let checkableIDs: [UUID]
        let checkableBytes: Int64
        /// "Hash all": the unhashed related rows + the family members
        /// with no hash (so the keys can compare).
        let hashAllIDs: [UUID]
        /// Rows whose file is gone from a connected volume — what "Remove
        /// N missing rows" tombstones.
        let missingIDs: [UUID]
    }

    struct Item: Identifiable, Equatable {
        enum Kind: Equatable {
            case family(FamilyHeader)
            case copy(PrunePlan.CopyRow)
            /// "Might be copies" sub-header (count listed, count hidden).
            case relatedHeader(count: Int, hidden: Int)
            /// One related row and what its Hash button hashes.
            case related(PrunePlan.RelatedRow, hashIDs: [UUID])
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

    static func header(_ family: PrunePlan.Family) -> FamilyHeader {
        let key = family.key.isEmpty ? family.displayName : family.key
        let unhashedRelated = family.related.filter { $0.status == .needsHash }.map(\.id)
        return FamilyHeader(name: family.displayName, key: key, level: family.level.displayName,
                            advice: family.advice, note: family.note,
                            archiveCount: family.archive.count, archiveVerified: family.archiveVerified,
                            versionArchiveCount: family.versionArchive.count,
                            checkableIDs: family.checkableIDs, checkableBytes: family.checkableBytes,
                            hashAllIDs: unhashedRelated.isEmpty ? [] : unhashedRelated + family.unhashedMemberIDs,
                            missingIDs: family.missingIDs)
    }

    static func build(_ plan: PrunePlan, maxRows: Int = maxRows) -> PruneChecklist {
        var items: [Item] = []
        var visible = Set<UUID>()
        items.reserveCapacity(min(plan.rowCount, maxRows) + plan.families.count * 2 + plan.relatedCount)
        // `budget` is spent only by the capped (no-default-check) families,
        // so a big default set never starves them of their 200 rows.
        var budget = maxRows, hidden = 0
        func list(_ i: Int, _ family: PrunePlan.Family, capped: Bool) {
            if capped, budget <= 0 { hidden += family.rows.count; return }
            let head = header(family)
            items.append(Item(id: "f\(i)", kind: .family(head)))
            for row in family.rows {
                if capped {
                    if budget <= 0 { hidden += 1; continue }
                    budget -= 1
                }
                items.append(Item(id: row.id.uuidString, kind: .copy(row)))
                visible.insert(row.id)
            }
            if !family.related.isEmpty {
                items.append(Item(id: "f\(i)r", kind: .relatedHeader(count: family.related.count,
                                                                     hidden: family.relatedHiddenCount)))
                for r in family.related {
                    let hashIDs = r.status == .needsHash ? [r.id] + family.unhashedMemberIDs : []
                    items.append(Item(id: "r" + r.id.uuidString, kind: .related(r, hashIDs: hashIDs)))
                }
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
    let hashing: Set<UUID>
    let archiveLabel: String
    @Binding var keepOne: Bool
    @Binding var keeperVolume: String?
    /// The keep-one helper changed: recompute the DEFAULT checks.
    let onDefaultsChanged: () -> Void
    let onCheck: (UUID, Bool) -> Void
    /// Select all / none over a set of checkable ids.
    let onSelect: ([UUID], Bool) -> Void
    /// Hash to confirm these records, then re-plan.
    let onHash: ([UUID]) -> Void
    /// Remove these missing-file rows from the catalog, then re-plan.
    let onRemoveMissing: ([UUID]) -> Void

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                keeperRow
                if plan.rowCount > 0 || plan.relatedCount > 0 { list }
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
            let all = Array(plan.checkableIDs.intersection(checklist.visibleIDs))
            Button("Select all deletable copies (\(all.count), \(MediaBytes.display(plan.checkableBytes)))") {
                onSelect(all, true)
            }
            .font(.system(size: 11))
            .disabled(all.isEmpty)
            .accessibilityIdentifier("whatNext.selectAll")
            Button("Select none") { onSelect(all, false) }
                .font(.system(size: 11))
                .disabled(selected.isEmpty)
                .accessibilityIdentifier("whatNext.selectNone")
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
                    case .family(let head):
                        familyHeader(head)
                    case .copy(let row):
                        copyRow(row)
                    case .relatedHeader(let count, let hidden):
                        relatedHeader(count: count, hidden: hidden)
                    case .related(let row, let hashIDs):
                        relatedRow(row, hashIDs: hashIDs)
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
        .frame(minHeight: 120, maxHeight: .infinity)
    }

    private func familyHeader(_ h: PruneChecklist.FamilyHeader) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(h.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("· \(h.level)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(h.archiveVerified
                     ? "✓ In \(archiveLabel), verified (\(h.archiveCount) file\(h.archiveCount == 1 ? "" : "s"))"
                     : (h.archiveCount == 0 ? "✗ Not in \(archiveLabel)" : "✗ In \(archiveLabel), not verified"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(h.archiveVerified ? .green : .orange)
                    .accessibilityIdentifier("whatNext.family.\(h.key).archive")
                if h.versionArchiveCount > 0 {
                    Text(h.archiveCount == 0
                         ? "(only a version is archived — not the original)"
                         : "(+ \(h.versionArchiveCount) version\(h.versionArchiveCount == 1 ? "" : "s") archived)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("whatNext.family.\(h.key).versionArchive")
                }
                Spacer(minLength: 4)
                if !h.checkableIDs.isEmpty {
                    Button("Select all deletable") { onSelect(h.checkableIDs, true) }
                        .font(.system(size: 10))
                        .controlSize(.small)
                        .accessibilityIdentifier("whatNext.family.\(h.key).selectAll")
                    Button("Select none") { onSelect(h.checkableIDs, false) }
                        .font(.system(size: 10))
                        .controlSize(.small)
                        .accessibilityIdentifier("whatNext.family.\(h.key).selectNone")
                }
                if !h.hashAllIDs.isEmpty {
                    Button("Hash all to confirm") { onHash(h.hashAllIDs) }
                        .font(.system(size: 10))
                        .controlSize(.small)
                        .disabled(h.hashAllIDs.contains { hashing.contains($0) })
                        .accessibilityIdentifier("whatNext.family.\(h.key).hashAll")
                }
                if h.missingIDs.count > 1 {
                    Button("Remove \(h.missingIDs.count) missing rows") { onRemoveMissing(h.missingIDs) }
                        .font(.system(size: 10))
                        .controlSize(.small)
                        .help("These files are not on their drive any more. Removes the catalog rows only — nothing on disk is touched.")
                        .accessibilityIdentifier("whatNext.family.\(h.key).removeMissing")
                }
            }
            if let advice = h.advice {
                Text(advice)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("whatNext.family.\(h.key).advice")
            }
            if let note = h.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("whatNext.family.\(h.key).note")
            }
        }
        .padding(.top, 8)
    }

    private func copyRow(_ row: PrunePlan.CopyRow) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { selected.contains(row.id) }, set: { onCheck(row.id, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!row.checkable)
                .accessibilityIdentifier("whatNext.copy.\(row.id.uuidString).check")
            Text(row.copy.volumeName.isEmpty ? "—" : row.copy.volumeName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
            Text(row.copy.fullPath)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(row.checkable ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.copy.fullPath)
            Text(MediaBytes.display(row.copy.sizeBytes))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .trailing)
            chip(row.kind.chip, tint: row.kind.isVersion ? .purple : (row.kind == .original ? .blue : .gray))
                .frame(width: 96, alignment: .leading)
            if row.isMissingFile {
                HStack(spacing: 6) {
                    Text(row.reasonText ?? "")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(row.reasonText ?? "")
                    Button("Remove from catalog") { onRemoveMissing([row.id]) }
                        .font(.system(size: 10))
                        .controlSize(.small)
                        .help("The file is not on its drive any more. Removes this catalog row only — nothing on disk is touched.")
                        .accessibilityIdentifier("whatNext.copy.\(row.id.uuidString).removeMissing")
                }
                .frame(width: 250, alignment: .leading)
            } else {
                Text(row.reasonText ?? "")
                    .font(.system(size: 10))
                    .foregroundColor(row.checkable ? .secondary : .orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 250, alignment: .leading)
                    .help(row.reasonText ?? "")
            }
        }
        .padding(.leading, 12)
    }

    private func relatedHeader(count: Int, hidden: Int) -> some View {
        Text("Might be copies — same name, not confirmed by content (\(count)\(hidden > 0 ? ", \(hidden) more not listed" : ""))")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.leading, 12)
            .padding(.top, 4)
    }

    private func relatedRow(_ row: PrunePlan.RelatedRow, hashIDs: [UUID]) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: .constant(false))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(true)
            Text(row.copy.volumeName.isEmpty ? "—" : row.copy.volumeName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
            Text(row.copy.fullPath)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.copy.fullPath)
            Text(MediaBytes.display(row.copy.sizeBytes))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .trailing)
            chip(row.status == .needsHash ? "unhashed" : "different", tint: .gray)
                .frame(width: 96, alignment: .leading)
            HStack(spacing: 6) {
                if row.status == .needsHash {
                    if hashing.contains(row.id) {
                        ProgressView().controlSize(.mini)
                        Text("hashing…").font(.system(size: 10)).foregroundColor(.secondary)
                    } else {
                        Button("Hash to confirm") { onHash(hashIDs) }
                            .font(.system(size: 10))
                            .controlSize(.small)
                            .accessibilityIdentifier("whatNext.related.\(row.id.uuidString).hash")
                    }
                } else {
                    Text(row.reasonText)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 250, alignment: .leading)
        }
        .padding(.leading, 12)
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.15)))
            .foregroundColor(tint)
            .lineLimit(1)
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
