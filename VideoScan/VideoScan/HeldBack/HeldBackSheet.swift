// HeldBackSheet.swift — GH #339: Catalog Status ▸ "Held back at import: N —
// why" ▸ Show…. The READ-ONLY list of the rows the October import held back,
// grouped by where each file is now (each group says what was checked), and
// — after Find Moved Copies — the proven pairs Rick may confirm.
//
// Nothing here writes. The list reads `store.sections` (computed once per
// load, never in this body — no O(records) work here); Find Moved Copies is
// the MFO job; Carry Selected… asks once more and then calls the store's
// one writer, which re-checks every pair against the catalog and the disk.
//
// (For Rick: a dumb view over the store's published values; the only
// actions are "start the job" and "call carry(ids)".)

import SwiftUI
import VideoScanCore

struct HeldBackSheet: View {
    @ObservedObject var store: HeldBackStore
    let center: MediaFileOperationsCenter
    let isReadOnly: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var confirming = false
    @State private var jobNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(HeldBackWords.sheetTitle).font(.title2.weight(.semibold))
            Text(HeldBackWords.sheetLead).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            stateLine
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !store.offers.isEmpty { offersSection }
                    ForEach(store.sections) { section in
                        sectionView(section)
                    }
                }
                .padding(.vertical, 4)
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 560, idealHeight: 720)
        .accessibilityIdentifier("sheet.heldBack")
        .task { if store.listState == .idle { await store.loadList() } }
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            Button("Carry") { _ = store.carry(selected); selected = [] }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only fields the live file does not have yet are set; nothing you already set is changed, and an archived file's date is never touched. Each held-back row is then closed and kept as history.")
        }
    }

    private var confirmTitle: String {
        let n = selected.count
        return "Carry onto \(n) file\(n == 1 ? "" : "s")?"
    }

    @ViewBuilder
    private var stateLine: some View {
        switch store.listState {
        case .idle, .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the held-back rows and checking the disk…") }
                .foregroundStyle(.secondary)
        case .loaded(let at):
            Text("\(store.entries.count.formatted()) rows · \((store.openCount ?? 0).formatted()) open · checked \(MediaDistributionFormat.timeString(at))")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let why):
            Text("Could not read the held-back rows — \(why)").foregroundStyle(.red)
        }
    }

    private func sectionView(_ section: HeldBackSection) -> some View {
        DisclosureGroup {
            Text(section.group.evidence).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(section.entries) { entry in entryRow(entry) }
        } label: {
            Text("\(section.group.title) — \(section.entries.count.formatted())").font(.headline)
                .accessibilityIdentifier("heldBack.group.\(section.group.rawValue)")
        }
    }

    private func entryRow(_ e: HeldBackEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(e.filename) — \(e.drive) · \(HeldBackWords.size(e.sizeBytes)) (as recorded)").font(.callout.weight(.medium))
            Text(e.fullPath).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Text("Why held back: \(HeldBackWords.reason(e.reasonCode)) — \(e.words)").font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text("It carried: \(HeldBackWords.curated(e.curated))").font(.caption).foregroundStyle(.secondary)
            if case .resolved(let note) = e.whereNow {
                Text(note).font(.caption).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 8)
    }

    // MARK: Offers

    private var offersSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Each pair below was proven the same content, read from the live file just now. Tick the ones to carry; nothing is written until you confirm.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(store.offers) { offer in offerRow(offer) }
                if !store.lastCarryLines.isEmpty {
                    ForEach(store.lastCarryLines, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                }
            }
            .padding(4)
        } label: {
            Text("Moved copies proven — \(store.offers.count.formatted())").font(.headline)
        }
    }

    private func offerRow(_ o: HeldBackOffer) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { selected.contains(o.id) },
                                     set: { if $0 { selected.insert(o.id) } else { selected.remove(o.id) } }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(!o.isSelectable || isReadOnly)
                .accessibilityIdentifier("heldBack.offer.\(o.id)")
            VStack(alignment: .leading, spacing: 2) {
                Text("\(o.oldName) → \(o.liveName)").font(.callout.weight(.medium))
                Text(o.livePath).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text("Proof: \(o.evidence.words)").font(.caption)
                ForEach([HeldBackWords.field("Tag", o.fields.tag), HeldBackWords.field("Date", o.fields.date),
                         HeldBackWords.field("Place", o.fields.place)].compactMap { $0 }, id: \.self) { Text($0).font(.caption) }
                if case .carry(let tag)? = o.fields.tag, tag == MediaDisposition.confirmedJunk.rawValue {
                    Text("Confirmed Junk: Delete Junk may then offer this live file for the Trash.").font(.caption).foregroundStyle(.orange)
                }
                if o.fields.allAlready { Text("Already on the live file — confirming only closes the held-back row.").font(.caption) }
                if let why = o.blocked { Text("Not offered: \(why)").font(.caption).foregroundStyle(.orange) }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button(HeldBackWords.findButton) { startJob() }
                .disabled(store.listState == .loading || store.entries.isEmpty)
                .help("Reads each gone row's same-name, same-size live file and proves it by content. Writes nothing.")
                .accessibilityIdentifier("heldBack.find")
            Button("Check Again") { Task { await store.loadList() } }
                .disabled(store.listState == .loading)
                .help("Reads the rows again and checks the disk now (stat only).")
            if let jobNote { Text(jobNote).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(HeldBackWords.carryButton) { confirming = true }
                .disabled(selected.isEmpty || isReadOnly || store.writeRefusal != nil)
                .help(store.writeRefusal ?? "Asks once more, then carries the ticked values.")
                .accessibilityIdentifier("heldBack.carry")
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    private func startJob() {
        let plan = store.jobPlan()
        guard !plan.tasks.isEmpty else {
            jobNote = "Nothing to check: no gone row has a same-name, same-size live file and something to carry."
            return
        }
        let store = self.store
        let started = center.startedByUser {
            $0.startFindMovedCopies(plan: plan, note: { store.note($0) }, deliver: { store.setOffers($0) })
        }
        jobNote = started == nil ? "Find Moved Copies is already running." : "Started — its row in Media File Operations shows progress, Pause and Stop."
    }
}
