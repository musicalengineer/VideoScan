// ArchivedWhatNextSheet.swift
// "Archived — what next?" (promote-and-prune stage 2, Rick 2026-09-12,
// docs/promote_and_prune_workflow_design.md §"The sheet") — DRY RUN ONLY.
//
// Appears once per Promote batch, only when every copy landed verified
// (never mid-batch, never on a failed file), and from Tidy → "Copies of
// archived media" for the backlog. Shows: the summary line, the
// protection line, the 3-2-1 tip, the attestation controls (cloud /
// off-site, each yes-with-label / no / n-a, scope this batch vs only
// ★★★), and the plan — keep-one-working-copy picker, count + size of the
// copies that WOULD go to the Trash, the "not covered by the bar" line.
//
// Apply is DISABLED ("Dry run — Apply arrives after a few days of real
// batches"): Rick ruled dry-run first, so the numbers can be seen on real
// batches. "Not now" dismisses. Attestation choices DO persist — they are
// stage 1's `recordAttestation` (catalog record + attestation journal)
// and write a ledger `attestation` line — and the plan recomputes after
// each answer because the bar depends on them.
//
// Body discipline: every section is its own small view/builder (giant
// SwiftUI bodies fail on the CI runner); the plan is computed off-main by
// the model (`prunePlan(for:options:)`), never in the body.

import SwiftUI

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
    @State private var showTrashList = false
    @State private var showNotCoveredList = false

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
        .frame(width: 640)
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
    /// attestation journal + ledger line), then recompute the plan.
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
            PrunePlanSection(plan: plan, keepOne: $keepOne, keeperVolume: $keeperVolume,
                             showTrashList: $showTrashList, showNotCoveredList: $showNotCoveredList,
                             onChange: { planRevision &+= 1 })
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Working out the extra copies…")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
        }
    }

    private func reloadPlan() async {
        let options = PrunePlan.Options(keepOne: keepOne, keeperVolume: keeperVolume, bar: model.importanceBar)
        let ids = request.recordIDs
        async let computed = model.prunePlan(for: ids, options: options)
        async let fresh = model.batchProtection(for: ids)
        let (p, prot) = await (computed, fresh)
        guard !Task.isCancelled else { return }
        plan = p
        protection = prot
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Spacer()
                Button("Not now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("whatNext.notNow")
                Button(applyTitle) {}
                    .disabled(true)
                    .accessibilityIdentifier("whatNext.apply")
            }
            Text("Dry run — Apply arrives after a few days of real batches.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .accessibilityIdentifier("whatNext.dryRunCaption")
        }
    }

    private var applyTitle: String {
        let n = plan?.trashCount ?? 0
        return n == 0 ? "Apply" : "Apply — Trash \(n) file\(n == 1 ? "" : "s")"
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

// MARK: - The plan (dry run)

struct PrunePlanSection: View {
    let plan: PrunePlan
    @Binding var keepOne: Bool
    @Binding var keeperVolume: String?
    @Binding var showTrashList: Bool
    @Binding var showNotCoveredList: Bool
    let onChange: () -> Void

    private static let maxListRows = 200

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                keeperRow
                trashRow
                notCoveredRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var title: String {
        let n = plan.extraCount
        return n == 0
            ? "No extra copies outside the archive"
            : "What to do with the \(n) extra cop\(n == 1 ? "y" : "ies") (\(MediaBytes.display(plan.extraBytes)))"
    }

    private var keeperRow: some View {
        HStack(spacing: 8) {
            Toggle("Keep one working copy", isOn: $keepOne)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .onChange(of: keepOne) { onChange() }
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
            .onChange(of: keeperVolume) { onChange() }
            .accessibilityIdentifier("whatNext.keeperVolume")
            if plan.keeperRequiredCount > 0 {
                Text("(required for \(plan.keeperRequiredCount) ★★/★★★ file\(plan.keeperRequiredCount == 1 ? "" : "s"))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func volumeLabel(_ v: PrunePlan.VolumeChoice) -> String {
        guard let free = v.freeBytes else { return v.name }
        return "\(v.name) — \(MediaBytes.display(free)) free"
    }

    @ViewBuilder
    private var trashRow: some View {
        let n = plan.trashCount
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .foregroundColor(n == 0 ? .secondary : .orange)
                Text(n == 0
                     ? "Nothing would go to the Trash."
                     : "Move the other \(n) cop\(n == 1 ? "y" : "ies") to the Trash — \(MediaBytes.display(plan.trashBytes))")
                    .font(.system(size: 12))
                    .accessibilityIdentifier("whatNext.trashLine")
                if n > 0 {
                    Button(showTrashList ? "hide list" : "list…") { showTrashList.toggle() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
            if showTrashList, n > 0 {
                fileList(plan.trashFiles.map { "\($0.volumeName): \($0.filename)" })
            }
        }
    }

    @ViewBuilder
    private var notCoveredRow: some View {
        let families = plan.notCoveredFamilies
        if !families.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "shield.slash")
                        .foregroundColor(.secondary)
                    Text("\(families.count) file\(families.count == 1 ? " is" : "s are") not covered by the bar you set: \(families.count == 1 ? "it keeps" : "they keep") all copies until you attest one.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("whatNext.notCoveredLine")
                    Button(showNotCoveredList ? "hide list" : "list…") { showNotCoveredList.toggle() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
                if showNotCoveredList {
                    fileList(families.map { "\($0.displayName) — \($0.shortfall ?? "")" })
                }
            }
        }
    }

    private func fileList(_ rows: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(rows.prefix(Self.maxListRows).enumerated()), id: \.offset) { _, row in
                    Text(row)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if rows.count > Self.maxListRows {
                    Text("… and \(rows.count - Self.maxListRows) more")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140)
        .padding(.leading, 22)
    }
}
