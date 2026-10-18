// CatalogAdoptSQLite.swift
// Catalog ▸ "Adopt This SQLite Catalog…" (cutover B2.1 gap 5, design §3
// "Outcomes and words"). One sentence: when catalog.sqlite opened READ-ONLY
// because it is below the high-water this Mac already wrote (a restore, or
// a crash between a high-water write and its commit), the person may say
// "this copy is the catalog now", and writing resumes.
//
// Steps, each refusing before it changes anything:
//   1. enabled only when the store OPENED `.readOnly(restoredBelowHighWater…)`
//      — never for a poisoned witness or any other read-only reason;
//   2. the sheet names both numbers: the generation this catalog.sqlite is
//      at and the high-water this Mac wrote (the higher of catalog.highwater
//      and the last line of catalog.highwater.log), and what adopting means;
//   3. Adopt → `repository.adopt(toHighWater:)` (the store raises its
//      generation to the high-water with an `adopt` history row, witnesses
//      first) → writes allowed again → the committer commits what changed
//      while it was read-only. The records are NOT reloaded: they were
//      loaded from this very file and nothing could be written to it since,
//      so a reload would only throw away edits made meanwhile.
// Outcomes: adopted(from, to) · refused(the store's words) · notAdoptable.
// START / OUTCOME lines through the model's one sink.
//
// (For Rick: an explicit "accept this older copy" button — a person's act,
// never automatic, because the newer copy may still exist somewhere.)

import SwiftUI
import VideoScanCore

/// The Adopt sheet's item: the two numbers it names.
struct CatalogAdoptRequest: Identifiable, Equatable {
    let id = UUID()
    let databaseGeneration: Int
    let highWater: Int
    let reason: String
}

enum CatalogAdopt {

    /// The high-water this Mac wrote beside the database: the higher of
    /// the sidecar and the ledger's last line (nil when neither is readable).
    static func highWater(besideDatabaseAt url: URL) -> Int? {
        var values: [Int] = []
        if case .value(let v) = CatalogHighWater.read(besideDatabaseAt: url) { values.append(v) }
        if case .value(let v) = CatalogHighWaterLedger.read(besideDatabaseAt: url) { values.append(v) }
        return values.max()
    }
}

extension CatalogCutoverState {

    /// Step 2: the request the sheet shows (nil = not adoptable now).
    func adoptRequestIfAdoptable() async -> CatalogAdoptRequest? {
        guard canAdopt, let committer, let databaseURL, let reason = readOnlyReason,
              let highWater = CatalogAdopt.highWater(besideDatabaseAt: databaseURL) else { return nil }
        let generation = await committer.repository.generation
        guard highWater > generation else { return nil }
        return CatalogAdoptRequest(databaseGeneration: generation, highWater: highWater, reason: reason)
    }

    /// Step 3. Returns the words the sheet shows.
    func adopt(_ request: CatalogAdoptRequest) async -> CatalogAdoptOutcome {
        guard canAdopt, let committer else { return .refused(reason: "this catalog is not waiting to be adopted") }
        return await committer.adopt(toHighWater: request.highWater)
    }
}

// MARK: - Menu item

struct CatalogAdoptMenuItem: View {
    @ObservedObject var cutover: CatalogCutoverState

    var body: some View {
        Button("Adopt This SQLite Catalog…") {
            Task { @MainActor in cutover.adoptRequest = await cutover.adoptRequestIfAdoptable() }
        }
        .disabled(!cutover.canAdopt)
        .help(cutover.canAdopt
              ? "This catalog.sqlite is older than the last generation this Mac wrote, so it opened read-only. Adopt it to write to it again."
              : "Only offered when catalog.sqlite opened read-only because it is older than the last generation this Mac wrote.")
        .accessibilityIdentifier("catalog.menu.adoptSQLite")
    }
}

// MARK: - The sheet

struct CatalogAdoptSheet: View {
    @ObservedObject var cutover: CatalogCutoverState
    let request: CatalogAdoptRequest
    @Environment(\.dismiss) private var dismiss
    @State private var outcome: CatalogAdoptOutcome?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adopt This SQLite Catalog").font(.title2.weight(.semibold))
            Text("This catalog.sqlite is at generation \(request.databaseGeneration), but this Mac already wrote generation "
                 + "\(request.highWater). It is an older copy — a restore, or a crash between a save and its high-water mark.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Adopt makes this copy the catalog: its generation jumps to \(request.highWater) (recorded in the catalog's history), "
                 + "writing resumes, and the changes you made while it was read-only are saved. Anything in the newer copy that is "
                 + "not in this one stays in that copy. If the newer copy still exists, open it instead.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            outcomeView
            HStack {
                Spacer()
                if outcome == nil {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Adopt generation \(request.databaseGeneration) as \(request.highWater)") { start() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(running)
                } else {
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .accessibilityIdentifier("sheet.adoptSQLite")
    }

    @ViewBuilder private var outcomeView: some View {
        switch outcome {
        case .adopted(let from, let to):
            Text("Adopted: generation \(from) is now \(to). Saving to catalog.sqlite again.").font(.system(size: 12))
        case .refused(let words):
            Text("Not adopted: \(words)").foregroundStyle(.red).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        case nil:
            if running { ProgressView().controlSize(.small) }
        }
    }

    private func start() {
        running = true
        Task { @MainActor in
            outcome = await cutover.adopt(request)
            running = false
        }
    }
}
