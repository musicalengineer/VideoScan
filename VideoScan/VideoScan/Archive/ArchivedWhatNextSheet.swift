// ArchivedWhatNextSheet.swift
// "Archived — what next?" (promote-and-prune, Rick 2026-09-12; simplified
// 2026-10-21, docs/design/pruneplan_simple_2026-10-21.md).
//
// Appears once per Promote batch, only when every copy landed verified, and
// from Tidy → "Copies of archived media" for the backlog. Shows the summary
// line, the protection line, the attestation controls (cloud / off-site:
// yes-with-label / no / n-a — RECORDED on each file and in the archive's
// journal, advice only), and the one prune list (PruneChecklistView): every
// byte-identical copy outside the archive checked by default, everything
// else listed with its "no obvious choices" reason.
//
// Rick's rule: "Check for dups and copies, offer to delete; if none, say so;
// otherwise let the user delete what he wants. If it is too difficult to
// figure out, don't prune — say 'no obvious choices'."
//
// Apply → a PruneApplyJob in Media File Operations (nothing long runs behind
// a modal) carrying the plan that was SHOWN; it re-plans at its turn and
// reads each copy and its archive copy in full before the Trash. "Not now"
// dismisses.
//
// Body discipline: the plan is built off-main by the model and capped to
// 200 rows (`PrunePlan.shown()`); the body never walks `records`.
// (For Rick: `@State` ≈ a member the view owns and re-renders on change.)

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
    @State private var plan: PrunePlan?
    @State private var protection: ProtectionSummary
    /// Bumped whenever an input the plan depends on changes.
    @State private var planRevision = 0
    @State private var logged = false
    /// Every offered row starts checked; once the person touches a box, the
    /// choice survives a reload (minus anything no longer offered).
    @State private var selected: Set<UUID> = []
    @State private var selectionTouched = false
    @State private var reloading = false

    @State private var confirmingApply = false
    @State private var applying = false

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
            return "\(n) cop\(n == 1 ? "y" : "ies") (\(size)) outside the Master Archive \(n == 1 ? "is" : "are") byte-for-byte a verified archive file."
        }
    }

    // MARK: Protection + attestations (recorded; advice only)

    private var protectionSection: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("Protection now:")
                .font(.system(size: 12, weight: .semibold))
            Text(protection.displayLine)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("whatNext.protectionLine")
        }
    }

    private var attestationSection: some View {
        GroupBox("I also have these files…") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 24) {
                    AttestationAnswerRow(kind: .cloud, answer: $cloudAnswer, label: $cloudLabel,
                                         placeholder: "in: iCloud, Backblaze…", onCommit: { record(.cloud) })
                    AttestationAnswerRow(kind: .offsite, answer: $offsiteAnswer, label: $offsiteLabel,
                                         placeholder: "at: Tim's house…", onCommit: { record(.offsite) })
                }
                HStack(spacing: 10) {
                    Picker("Applies to:", selection: $onlyImportant) {
                        Text("this batch").tag(false)
                        Text("only the ★★★ ones").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .font(.system(size: 11))
                    Text("Your word is remembered on each file (and in the archive's manifest). It is advice: it never holds or releases a copy. VideoScan never checks a cloud or off-site copy.")
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

    /// Persist one kind's answer (catalog + attestation journal + ledger
    /// line), then re-plan — the protection line and the advice read it.
    private func record(_ kind: BackupAttestation.Kind) {
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

    // MARK: The list

    @ViewBuilder
    private var planSection: some View {
        if let plan {
            GroupBox {
                PruneChecklistView(plan: plan, selected: selectionBinding, archiveLabel: request.archiveLabel)
                    .padding(.vertical, 4)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for copies…")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
        }
    }

    private var selectionBinding: Binding<Set<UUID>> {
        Binding(get: { selected }, set: { new in
            selected = new.intersection(plan?.offeredIDs ?? [])
            selectionTouched = true
        })
    }

    private func reloadPlan() async {
        reloading = true
        defer { reloading = false }
        let full = await model.prunePlan(batch: Set(request.recordIDs))
        guard !Task.isCancelled else { return }
        let shown = full.shown()
        plan = shown
        protection = full.protection
        selected = selectionTouched ? selected.intersection(shown.offeredIDs) : shown.offeredIDs
        if !logged {
            logged = true
            model.logPrunePlan(full, batchID: request.batchID)
        }
    }

    // MARK: Footer

    private var selectedCount: Int { plan?.selectedCount(selected) ?? 0 }

    private var footer: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Spacer()
                Button("Not now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("whatNext.notNow")
                if applying { ProgressView().controlSize(.small) }
                Button(PruneWords.actionTitle(count: selectedCount, bytes: plan?.selectedBytes(selected) ?? 0)) {
                    confirmingApply = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(!Self.canApply(selectedCount: selectedCount, applying: applying,
                                         readOnly: model.isReadOnly, reloading: reloading))
                .accessibilityIdentifier("whatNext.apply")
            }
            Text("The files in \(request.archiveLabel) and every copy you leave unchecked are never touched. Each copy goes only after it and its archive copy are read in full and match. Everything moved can be restored from the Trash.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("whatNext.applyCaption")
        }
        .confirmationDialog(confirmTitle, isPresented: $confirmingApply) {
            Button("Move to Trash") { runApply() }
                .accessibilityIdentifier("whatNext.confirmApply")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(plan.map { PruneWords.confirmMessage($0, selected: selected, archiveLabel: request.archiveLabel) } ?? "")
        }
    }

    /// Apply acts only on a non-empty selection, once, and never while the
    /// plan it would act on is being recomputed.
    static func canApply(selectedCount: Int, applying: Bool, readOnly: Bool, reloading: Bool = false) -> Bool {
        selectedCount > 0 && !applying && !readOnly && !reloading
    }

    private var confirmTitle: String {
        let n = selectedCount
        return "Move \(n) cop\(n == 1 ? "y" : "ies") (\(MediaBytes.display(plan?.selectedBytes(selected) ?? 0))) to the Trash?"
    }

    /// Hand the SHOWN plan + the person's checks to a Media File Operation
    /// and close. A second batch while one runs is queued, not refused; a
    /// refusal can still come from a safety gate — then say so and stay open.
    private func runApply() {
        guard let shown = plan, !reloading, !applying else { return }
        applying = true
        let n = selectedCount
        let job = fileOpsCenter.startedByUser {
            $0.startPruneApply(shown: shown, selected: selected, batch: Set(request.recordIDs),
                               batchID: request.batchID, model: model)
        }
        if job.wasRefused {
            let why: String
            if case .failed(let message) = job.state { why = message } else { why = "refused" }
            model.log("Archived — what next?: not started — \(why)")
            applying = false
            return
        }
        model.log("Archived — what next?: \(n) cop\(n == 1 ? "y" : "ies") "
                  + (job.isQueued ? "queued in Media File Operations — each is checked at its turn"
                                  : "to the Trash in Media File Operations — each is read in full first"))
        dismiss()
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
