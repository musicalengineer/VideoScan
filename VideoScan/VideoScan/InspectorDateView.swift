import SwiftUI

// MARK: - InspectorDateView
//
// "When Was This?" section of the catalog Inspector (Estimated Date,
// GH #117 v1 — 2026-07-19). One lenient text field + a two-state
// best-guess / certain control, DEFAULT best-guess: the deliberate
// click is marking a date as known, never the other way around.
//
// Entry grammar lives in VideoScanCore's UserDateEntry (pure, tested):
// "1992", "6/1992", "6/14/1992", "1992-06", "1992-06-14" → canonical
// reduced-ISO. A year is plenty — the partial date IS the precision.
//
// Persistence follows InspectorFamilyTagsView exactly: mutate the
// record's fields, then post .videoScanCatalogMutated so VideoScanModel
// runs its debounced catalog save. VideoRecord is @Observable-free
// (plain class), so nothing saves implicitly — the explicit post IS the
// save call (the settings-persistence didSet trap doesn't bite here,
// but the same "explicit save, always" discipline applies).
//
// The parent embeds this with `.id(record.id)` so @State (draft text,
// confidence toggle) reseeds when the selection changes — otherwise
// SwiftUI would keep the previous record's draft in the same view slot.
// (`@State` ≈ a member variable owned by the framework per view
// IDENTITY, not per struct instance — the struct is rebuilt every
// render, the State survives until the identity changes.)

struct InspectorDateView: View {

    let record: VideoRecord

    @State private var entryText: String
    @State private var isKnown: Bool
    @State private var entryRejected = false
    /// Bump to force a redraw after mutating the (non-observable)
    /// record — same refreshTick idiom as InspectorFamilyTagsView.
    @State private var refreshTick = 0

    init(record: VideoRecord) {
        self.record = record
        // Seed the draft from the record. `_entryText = State(...)` is
        // how you set a @State's initial value from init (assigning
        // `entryText` here would be discarded by SwiftUI).
        _entryText = State(initialValue: record.userDate ?? "")
        _isKnown = State(initialValue: record.userDateStatus == .known)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("When was this? A year is plenty.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            HStack(spacing: 6) {
                TextField("1992  ·  6/1992  ·  6/14/1992", text: $entryText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: 150)
                    .onSubmit(saveEntry)
                    // Gauntlet flow 3 hooks (set-a-date) — test-only, UI unchanged.
                    .accessibilityIdentifier("inspector.date.field")
                Button("Save") { saveEntry() }
                    .controlSize(.small)
                    .accessibilityIdentifier("inspector.date.save")
                if record.userDate != nil {
                    Button("Clear") { clearEntry() }
                        .controlSize(.small)
                        .help("Forget this date — the file goes back to needing one")
                        .accessibilityIdentifier("inspector.date.clear")
                }
            }

            Picker("", selection: $isKnown) {
                Text("Best guess").tag(false)
                Text("I'm sure").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 180)
            .help("\"I'm sure\" means you're certain at the precision you entered — a bare year marked sure means the YEAR is certain.")
            .onChange(of: isKnown) {
                // Flipping confidence on an already-saved date saves
                // immediately; with no saved date it just sets the
                // default for the next Save.
                guard record.userDate != nil else { return }
                saveEntry()
            }
            .accessibilityIdentifier("inspector.date.confidencePicker")

            if entryRejected {
                Text("Hmm, couldn't read that — try 1992, 6/1992, or 6/14/1992.")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .accessibilityIdentifier("inspector.date.rejected")
            }

            statusLine
        }
        .padding(.vertical, 4)
    }

    // MARK: Status line

    @ViewBuilder
    private var statusLine: some View {
        switch record.userDateStatus {
        case .known:
            savedLabel(text: "Saved: \(record.userDate ?? "") — you're sure",
                       icon: "checkmark.seal.fill", color: .accentColor)
        case .estimated:
            savedLabel(text: "Saved: \(record.userDate ?? "") — best guess",
                       icon: "questionmark.circle", color: .secondary)
        case .unconfirmed:
            Text("No date yet — even a rough year helps find this later.")
                .font(.system(size: 10))
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
        }
    }

    private func savedLabel(text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10))
        }
        .foregroundColor(color)
        // Gauntlet flow 3 asserts the saved wording here ("Saved: 1992 —
        // best guess" / "— you're sure").
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inspector.date.status")
    }

    // MARK: Mutations

    private func saveEntry() {
        let trimmed = entryText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Emptying the field and hitting Save/Return is a clear.
        guard !trimmed.isEmpty else {
            if record.userDate != nil { clearEntry() }
            return
        }
        guard let canonical = UserDateEntry.canonicalize(trimmed) else {
            entryRejected = true
            return
        }
        entryRejected = false
        entryText = canonical   // reflect the normalized form back
        record.userDate = canonical
        record.userDateConfidence = (isKnown ? UserDateConfidence.known
                                             : UserDateConfidence.estimated).rawValue
        save()
    }

    private func clearEntry() {
        entryText = ""
        entryRejected = false
        record.userDate = nil
        record.userDateConfidence = nil   // meaningless without a date
        save()
    }

    /// Explicit save through the normal catalog path: redraw this view,
    /// then let VideoScanModel's .videoScanCatalogMutated listener run
    /// the debounced catalog save (same shape as InspectorFamilyTagsView).
    private func save() {
        refreshTick &+= 1
        NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
    }
}
