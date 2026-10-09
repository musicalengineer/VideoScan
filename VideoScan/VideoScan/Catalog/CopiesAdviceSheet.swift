// CopiesAdviceSheet.swift
// "Copies & Advice…" — the card (design §10). READ-ONLY: it shows the
// `CopiesAdvice` value and hands every action to an existing door:
//
//   Show in Catalog ..... the app-wide `pendingCatalogSelection` hop
//                         (ContentView.handlePendingCatalogNavigation)
//   Reveal in Finder .... NSWorkspace.selectFile
//   Refresh ............. VideoScanModel.analyzeDuplicates() — the
//                         incremental Detect Duplicates pass — and, when
//                         this window has a job centre, Find Similar
//                         Footage scoped to this file
//   Move This Copy to
//   Trash… .............. Safe ONLY, never on the keeper or an archive
//                         copy. Asks once, re-derives the advice at the
//                         click, and only if it still says Safe hands the
//                         ONE record to VideoScanModel.trashSelectedRecords
//                         — the ⌘⌫ routine, with its own refusals. The
//                         card has no delete code of its own (pinned by
//                         CopiesAdviceSensorTests).
//
// The advice is built in `.task` (CopiesAdviceLoader: O(group) on main
// after one id-compare pass, the rest off main), never in `body`.
//
// (For Rick: `.task(id:)` ≈ a coroutine the view starts when it appears and
// restarts when `id` changes; SwiftUI cancels it when the sheet closes.)

import AppKit
import SwiftUI
import VideoScanCore

/// `.sheet(item:)` driver (the one-item-one-sheet rule).
struct CopiesAdviceRequest: Identifiable, Equatable {
    let id = UUID()
    let recordID: UUID
}

struct CopiesAdviceSheet: View {
    let request: CopiesAdviceRequest
    let model: VideoScanModel
    /// Starts Find Similar Footage for one file; nil when this window has
    /// no Media File Operations centre.
    var startFootageRun: ((FootageScope) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @AppStorage("selectedTab") private var selectedTab: Int = 0

    private enum Load: Equatable {
        case loading
        case loaded(CopiesAdvice)
        case gone
    }
    @State private var load: Load = .loading
    /// Bumped by Refresh and after a move: re-runs the `.task`.
    @State private var generation = 0
    @State private var refreshing = false
    @State private var confirmingTrash = false
    @State private var working = false
    @State private var outcome: String?

    private var advice: CopiesAdvice? {
        if case .loaded(let a) = load { return a }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Copies & Advice").font(.title2.weight(.semibold))
            switch load {
            case .loading:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking at the copies…") }
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            case .gone:
                Text("This file is no longer in the catalog.").foregroundColor(.secondary)
                Spacer(minLength: 0)
            case .loaded(let a):
                card(a)
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 820, minHeight: 420, idealHeight: 600)
        .task(id: generation) {
            let fresh = await CopiesAdviceLoader.load(recordID: request.recordID, model: model)
            load = fresh.map { .loaded($0) } ?? .gone
        }
        .alert("Move this copy to the Trash?", isPresented: $confirmingTrash, presenting: advice) { _ in
            Button("Move to Trash") { Task { await moveThisCopyToTrash() } }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { a in
            Text(CopiesAdviceText.confirmation(a))
        }
    }

    // MARK: The card

    @ViewBuilder
    private func card(_ a: CopiesAdvice) -> some View {
        Text(a.header.line)
            .font(.headline).lineLimit(1).truncationMode(.middle)
            .help(a.header.line)
        CopiesAdviceVerdictBox(verdict: a.verdict)
        if let outcome {
            Text(outcome).font(.callout).foregroundColor(.secondary)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                exactCopies(a)
                sameFootage(a)
                whyFlagged(a)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func exactCopies(_ a: CopiesAdvice) -> some View {
        CopiesAdviceSectionHeader(title: "EXACT COPIES (same bytes)", trailing: "\(a.copyCount) in all",
                                  freshness: a.duplicates.line("Copies"),
                                  stale: a.duplicates.needsRefresh)
        ForEach(a.rows) { row in
            CopiesAdviceCopyRow(row: row, onShow: { showInCatalog(row.id) }, onReveal: { reveal(row.fullPath) })
        }
        Text("Keeper: \(a.keeperReason)").font(.caption).foregroundColor(.secondary)
        ForEach(a.notes, id: \.self) { Text($0).font(.caption).foregroundColor(.secondary) }
    }

    @ViewBuilder
    private func sameFootage(_ a: CopiesAdvice) -> some View {
        CopiesAdviceSectionHeader(title: "SAME FOOTAGE (not the same bytes)", trailing: "\(a.sameFootage.count + a.sameFootageHidden)",
                                  freshness: a.footageFreshness.line("Footage groups"),
                                  stale: a.footageFreshness.needsRefresh)
        if a.sameFootage.isEmpty {
            Text("No other footage known to be the same event.").font(.callout).foregroundColor(.secondary)
        }
        ForEach(a.sameFootage) { m in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.filename).lineLimit(1).truncationMode(.middle)
                    Text("\(m.role) — \(m.detail)").font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Show in Catalog") { showInCatalog(m.id) }.buttonStyle(.link)
            }
        }
        if a.sameFootageHidden > 0 {
            Text("and \(a.sameFootageHidden) more").font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func whyFlagged(_ a: CopiesAdvice) -> some View {
        Text("WHY IT WAS FLAGGED").font(.caption.weight(.semibold)).foregroundColor(.secondary)
        ForEach(a.flagged, id: \.self) { Text($0).font(.callout) }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Refresh") { Task { await refresh() } }
                .disabled(refreshing || working || model.isAnalyzingDuplicates)
                .help("Check this file's copies again (Detect Duplicates — new or changed files only) and its footage group, then rebuild this card.")
            if refreshing { ProgressView().controlSize(.small) }
            if let a = advice, a.offersTrash {
                Button(CopiesAdviceText.trashButton) { confirmingTrash = true }
                    .disabled(working || model.isReadOnly)
                    .help("Moves only this copy to the Trash, through the same Move to Trash the Catalog uses. The keeper and the archive copy stay.")
                    .accessibilityIdentifier("copiesAdvice.moveThisCopyToTrash")
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }

    // MARK: Actions (each hands off to an existing door)

    private func showInCatalog(_ id: UUID) {
        model.pendingCatalogPairMode = false
        model.pendingCatalogSelection = id
        selectedTab = 1
        dismiss()
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    /// Detect Duplicates (incremental: new or changed files only) and, when
    /// this window can start jobs, Find Similar Footage for this one file;
    /// then rebuild the card.
    private func refresh() async {
        refreshing = true
        defer { refreshing = false }
        if let a = advice, a.footageFreshness.needsRefresh {
            startFootageRun?(.records([request.recordID]))
        }
        if !model.isAnalyzingDuplicates { await model.analyzeDuplicates() }
        generation &+= 1
    }

    /// Re-derive the advice NOW; only if it still says Safe, hand the one
    /// record to the ⌘⌫ routine. Nothing else here touches a file.
    private func moveThisCopyToTrash() async {
        working = true
        defer { working = false }
        guard let fresh = await CopiesAdviceLoader.load(recordID: request.recordID, model: model) else {
            load = .gone
            return
        }
        load = .loaded(fresh)
        guard fresh.offersTrash, let rec = model.record(forID: request.recordID) else {
            outcome = "Nothing was moved — the advice changed: \(fresh.verdict.sentence)."
            return
        }
        model.log("Copies & Advice: Move This Copy to Trash — \(fresh.rule.rawValue)")
        let result = await model.trashSelectedRecords([rec])
        outcome = CopiesAdviceText.trashOutcome(succeeded: result.succeeded, alreadyMissing: result.alreadyMissing,
                                                skippedOffline: result.skippedOffline, failed: result.failed.count)
        generation &+= 1
    }
}

// MARK: - Pieces

/// The ADVICE line: green for safe, orange for "check" / "connect",
/// neutral for keep. Readable in light and dark.
struct CopiesAdviceVerdictBox: View {
    let verdict: CopiesAdviceVerdict

    private var tint: Color {
        switch verdict.tone {
        case .safe: return .green
        case .attention: return .orange
        case .keep: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("ADVICE").font(.caption.weight(.bold)).foregroundColor(tint)
            Text(verdict.sentence).font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.35)))
        .accessibilityIdentifier("copiesAdvice.verdict")
    }
}

struct CopiesAdviceSectionHeader: View {
    let title: String
    let trailing: String
    let freshness: String
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundColor(.secondary)
                Spacer()
                Text(trailing).font(.caption).foregroundColor(.secondary)
            }
            Text(freshness).font(.caption2).foregroundColor(stale ? .orange : .secondary)
        }
        .padding(.top, 4)
    }
}

/// One copy: KEEPS / ►THIS / can go / stays, the drive, the path, and the
/// two hand-offs.
struct CopiesAdviceCopyRow: View {
    let row: CopiesAdviceRow
    let onShow: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(CopiesAdviceText.tag(row))
                .font(.caption.weight(.bold).monospaced())
                .frame(width: 92, alignment: .leading)
                .foregroundColor(row.fate == .keeps ? .green : (row.isThis ? .accentColor : .secondary))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.volume).fontWeight(.medium)
                    Text(row.fullPath).font(.caption).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(row.fullPath)
                }
                Text(CopiesAdviceText.facts(row)).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Show in Catalog", action: onShow).buttonStyle(.link)
            Button("Reveal", action: onReveal).buttonStyle(.link)
                .disabled(row.presence != .present)
                .help("Reveal in Finder")
        }
    }
}

// MARK: - Words for the card

extension CopiesAdviceText {

    /// The left-hand tag of a copy row.
    static func tag(_ r: CopiesAdviceRow) -> String {
        let fate: String
        switch r.fate {
        case .keeps: fate = "KEEPS"
        case .canGo: fate = "can go"
        case .stays: fate = "stays"
        case .checkFirst: fate = "check"
        }
        return r.isThis ? (r.fate == .keeps ? "KEEPS ►THIS" : "►THIS") : fate
    }

    /// "41 GB · same bytes, verified · archived ✓ fixity checked 2 Oct 2026 · stays: drive not connected"
    static func facts(_ r: CopiesAdviceRow) -> String {
        var parts = [ByteCountFormatter.string(fromByteCount: r.sizeBytes, countStyle: .file)]
        switch r.match {
        case .verified?: parts.append("same bytes, verified")
        case .sampled?: parts.append("matches by sample only")
        case nil: break
        }
        if r.isArchiveCopy { parts.append("archived ✓" + (r.fixity.map { " \($0)" } ?? "")) }
        else if let f = r.fixity { parts.append(f) }
        if r.isRetired { parts.append("retired drive") }
        if case .stays(let why) = r.fate, !why.isEmpty { parts.append("stays: \(why)") }
        if r.isThis, r.fate == .canGo { parts.append("can go") }
        return parts.joined(separator: " · ")
    }

    /// The one confirmation's message.
    static func confirmation(_ a: CopiesAdvice) -> String {
        let keeper = a.rows.first { $0.id == a.keeperID }
        let stays = keeper.map { "\($0.volume): \($0.fullPath)" } ?? "the keeper"
        return "\(a.header.filename) goes to the Trash on its own drive; you can put it back until you empty the Trash.\n\n"
            + "The keeper stays — \(stays)."
    }

    /// What the ⌘⌫ routine did with the one file, in plain words.
    static func trashOutcome(succeeded: Int, alreadyMissing: Int, skippedOffline: Int, failed: Int) -> String {
        if succeeded > 0 { return "Moved to the Trash. You can put it back from the Trash until you empty it." }
        if alreadyMissing > 0 { return "The file was already gone from its drive; the catalog now says so." }
        if skippedOffline > 0 { return "Nothing was moved — its drive isn't connected." }
        if failed > 0 { return "Nothing was moved — the Trash refused it. The console says why." }
        return "Nothing was moved — Move to Trash left it alone. The console says why."
    }
}
