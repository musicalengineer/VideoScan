import SwiftUI

// MARK: - RelocateRetireSheet
//
// §1B Retire Volume — post-Relocate modal. Surfaced automatically when
// `model.pendingRetireOffer != nil` (set by `maybeOfferRetire` after a
// run that disposed 100% of the source volume's records). Two buttons,
// no typed confirmation — fully reversible via the Reinstate context
// action in the Volumes window.
//
// Layout deliberately compact: headline + editable reason field +
// (Retire / Skip) button bar. Witness count is shown but the list itself
// isn't surfaced here — it's already in the relocate.log and the audit
// trail notes on each `.manuallyDeleted` record.

struct RelocateRetireSheet: View {

    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) var dismiss

    /// Snapshot passed in at sheet-init time. Owned by the parent's
    /// `.sheet(item:)` binding, so `dismiss()` plus clearing
    /// `model.pendingRetireOffer` tears the sheet down cleanly.
    let offer: PendingRetireOffer

    /// Editable copy of the suggested reason. Pre-populated from the
    /// offer; user can keep, edit, or clear before hitting Retire.
    @State private var reason: String

    init(offer: PendingRetireOffer) {
        self.offer = offer
        self._reason = State(initialValue: offer.suggestedReason)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Headline
            HStack(spacing: 10) {
                Image(systemName: "archivebox.fill")
                    .font(.title2)
                    .foregroundColor(.brown)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Retire \(offer.volumeName)?")
                        .font(.headline)
                        .accessibilityIdentifier("retireSheet.title")
                    Text("All \(offer.recordCount) catalogued record(s) on this volume are marked deleted.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // Body explanation
            Text("Retiring marks the volume itself as retired. It stops appearing in scan suggestions and the dashboard stops flagging it as offline. Records stay in the catalog for audit. Fully reversible.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(.secondary)
                .accessibilityIdentifier("retireSheet.body")

            // Reason editor
            VStack(alignment: .leading, spacing: 4) {
                Text("Reason")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $reason)
                    .font(.system(size: 13))
                    .frame(minHeight: 60, maxHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                    .accessibilityIdentifier("retireSheet.reason")
            }

            // Witness footnote (count only — the list itself is in the audit log)
            if !offer.witnesses.isEmpty {
                Text("\(offer.witnesses.count) witness path(s) will be recorded on the volume metadata.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("retireSheet.witnessCount")
            }

            // Button bar
            HStack {
                Spacer()
                Button("Skip for now") {
                    // Explicit no-op: dismiss + clear the pending offer.
                    // Volume can still be retired later via the context
                    // menu in the Volumes window.
                    model.pendingRetireOffer = nil
                    dismiss()
                }
                .keyboardShortcut(.escape)
                .accessibilityIdentifier("retireSheet.skip")

                Button("Retire \(offer.volumeName)") {
                    model.retireVolume(
                        at: offer.volumeRootPath,
                        reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                        witnesses: offer.witnesses
                    )
                    model.pendingRetireOffer = nil
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .accessibilityIdentifier("retireSheet.retire")
            }
        }
        .padding(20)
        .frame(minWidth: 520)
    }
}
