// ArchiveAngelReadyDisclosure.swift
// "10 ready to be promoted" — the second way to look at a prepared batch
// (Rick 2026-09-09): a chevron row directly ABOVE the Archive nudge ("It
// looks like 598 files are ready…"), so the eye lands on what is ACTUALLY
// prepared before the loose estimate. The turndown shows the same rows the
// review sheet shows, compact: checkbox · file · proposed archive name ·
// date · score · companion chips · first why-line. Renaming, dating and
// notes stay in the sheet ("Review & edit…"); Promote works from here.
// Each row has Show in Catalog / Show in Finder (Rick 2026-09-10: needed
// to judge whether a short clip is worth archiving or an edit of a longer
// original).

import SwiftUI

struct ArchiveAngelReadyDisclosure: View {
    @EnvironmentObject var model: VideoScanModel
    /// Forwarded to ArchiveAngelPromoter.promote(plan:model:center:) — intentional.
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject var fileOpsCenter: MediaFileOperationsCenter

    @State var plan: ArchiveAngelPlan
    /// Open the full review sheet for this batch.
    let openReview: () -> Void
    /// The batch list on disk changed (after Promote / edits) — re-read it.
    let batchesChanged: () -> Void

    @StateObject private var promoter = ArchiveAngelPromoter()
    @State private var isOpen = false

    private var ready: [ArchiveAngelPlan.Entry] { plan.entries.filter { $0.status == .ready } }
    private var selectedCount: Int { plan.selectedEntries.count }
    private var isPromoting: Bool { plan.status == .promoting }
    private var isDone: Bool { plan.status == .promoted }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Image(systemName: "sparkles").foregroundStyle(Color.orange)
                    Text(headline)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.orange)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("archive.angelReadyDisclosure")

            if isOpen {
                list.padding(.top, 8)
                footer.padding(.top, 8)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .onChange(of: plan) { _, new in
            // Every toggle is durable so the sheet and this row agree.
            try? ArchiveAngelPlanStore.save(new)
        }
    }

    private var headline: String {
        if isDone, let r = plan.report { return "Archive Angel: " + r.summary }
        if isPromoting { return "Archive Angel is promoting \(selectedCount)…" }
        let n = ready.count
        return "Archive Angel has \(n) video\(n == 1 ? "" : "s") ready to be promoted"
            + (selectedCount == n ? "" : " (\(selectedCount) selected)")
    }

    // MARK: Rows

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ready) { entry in
                row(entry)
                Divider()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func row(_ entry: ArchiveAngelPlan.Entry) -> some View {
        let idx = plan.entries.firstIndex(where: { $0.id == entry.id })
        return HStack(alignment: .top, spacing: 10) {
            if let idx {
                Toggle("", isOn: $plan.entries[idx].selected)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(isPromoting || isDone)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.filename)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(ArchiveAngelScorer.durationText(entry.durationSeconds)) · \(MediaBytes.display(entry.sizeBytes))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    ArchiveAngelRowActions(entry: entry)
                    Text("\(entry.score)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .help("Evidence points — the number only orders the list; the reasons are the text.")
                }
                HStack(spacing: 8) {
                    Text("→ \(entry.proposedName)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.purple)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(entry.proposedDate ?? "undated")
                        .font(.system(size: 11))
                        .foregroundStyle(entry.proposedDate == nil ? Color.orange : Color.secondary)
                }
                HStack(spacing: 6) {
                    ForEach(entry.steps) { step in chip(step.kind.label, state: step.state, note: step.note) }
                    if entry.isOriginalOnly {
                        Text("original only").font(.system(size: 10)).foregroundStyle(Color.orange)
                    }
                }
                if let why = entry.evidence.first?.line {
                    Text(why + (entry.evidence.count > 1 ? " · +\(entry.evidence.count - 1) more" : ""))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(entry.evidence.map(\.line).joined(separator: "\n"))
                }
                if let failure = entry.failure {
                    Text(failure).font(.system(size: 11)).foregroundStyle(Color.red)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .opacity(entry.selected ? 1 : 0.55)
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
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
        .help(note.isEmpty ? label : "\(label): \(note)")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(selectedCount) selected · \(MediaBytes.display(plan.bytesToCopy)) to copy · \(plan.rejectedTotal.formatted()) rejected · \(plan.overflow.formatted()) more would qualify")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if isPromoting, let job = promoter.job {
                Text(job.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Button("Review & edit…") { openReview() }
                .disabled(isPromoting)
            if isDone || (selectedCount == 0 && !isPromoting) {
                // Rick 2026-09-09: a greyed "Promote 0" after a promote reads
                // as stuck — say Done. The batch stays for the rest.
                Button("Done") { withAnimation { isOpen = false }; batchesChanged() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Promote \(selectedCount)") { promote() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isPromoting || model.isReadOnly)
                    .help("Runs the normal Promote job: originals from their source volume, companions from the buffer. Byte-verified, manifest rows, linked catalog records.")
            }
        }
    }

    private func promote() {
        var working = plan
        let job = promoter.promote(plan: &working, model: model, center: fileOpsCenter) { settled in
            plan = settled
            batchesChanged()
        }
        plan = working
        if job == nil {
            model.log("Archive Angel: nothing was started — " + (working.log.last ?? "see the batch log"))
        }
    }
}
