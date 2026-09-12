import SwiftUI

// MARK: - InspectorPlaceView
//
// "Where Was This?" section of the catalog Inspector (Rick 2026-09-12):
// the near-clone of InspectorDateView for a hand-entered PLACE. One free
// text field + a picker of Rick's OWN prior places + the same two-state
// best-guess / certain control, DEFAULT best-guess.
//
// Entry grammar lives in VideoScanCore's UserPlaceEntry (pure, tested):
// "franklin, ma" → "Franklin, MA", "cape cod" → "Cape Cod". Free text,
// no geocoding — a town or a region is plenty; the precision is whatever
// Rick typed, like the partial date.
//
// The picker reads `model.userPlaceRoster` — distinct places across the
// catalog by frequency then name, computed once per catalog change by
// VideoScanModel (NOT here; no O(records) work in a view body). Seeded
// with nothing: the list grows from use.
//
// Persistence follows InspectorDateView, with ONE difference: the
// mutation notification carries the record (`object: record`) so
// VideoScanModel refreshes that record's search-index entry — places are
// searchable (typing "cape" in the catalog bar must find the row at
// once), dates are not.
//
// The parent embeds this with `.id(record.id)` so @State reseeds when
// the selection changes.

struct InspectorPlaceView: View {

    let record: VideoRecord
    @EnvironmentObject var model: VideoScanModel

    @State private var entryText: String
    @State private var isKnown: Bool
    @State private var entryRejected = false
    /// Bump to force a redraw after mutating the (non-observable)
    /// record — same refreshTick idiom as InspectorDateView.
    @State private var refreshTick = 0

    init(record: VideoRecord) {
        self.record = record
        // (`_entryText = State(...)` is how a @State gets its initial
        // value from init — assigning `entryText` here would be discarded.)
        _entryText = State(initialValue: record.userPlace ?? "")
        _isKnown = State(initialValue: record.userPlaceStatus == .known)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where was this? A town or a region is plenty.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            HStack(spacing: 6) {
                TextField("Franklin, MA  ·  Cape Cod  ·  Montana", text: $entryText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(maxWidth: 170)
                    .onSubmit(saveEntry)
                    .accessibilityIdentifier("inspector.place.field")
                // Rick's own places — most used first. Free text stays
                // available beside it; picking fills the field and saves.
                if !model.userPlaceRoster.isEmpty {
                    Menu {
                        ForEach(model.userPlaceRoster.entries) { entry in
                            Button("\(entry.place)  (\(entry.count))") {
                                entryText = entry.place
                                saveEntry()
                            }
                        }
                    } label: {
                        Image(systemName: "mappin.and.ellipse")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Your places so far, most used first")
                    .accessibilityIdentifier("inspector.place.picker")
                }
                Button("Save") { saveEntry() }
                    .controlSize(.small)
                    .accessibilityIdentifier("inspector.place.save")
                if record.userPlace != nil {
                    Button("Clear") { clearEntry() }
                        .controlSize(.small)
                        .help("Forget this place — the file goes back to needing one")
                        .accessibilityIdentifier("inspector.place.clear")
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
            .help("\"I'm sure\" means you're certain at the precision you entered — \"Cape Cod\" marked sure means it was the Cape, not a particular beach.")
            .onChange(of: isKnown) {
                // Flipping confidence on an already-saved place saves
                // immediately; with no saved place it just sets the
                // default for the next Save.
                guard record.userPlace != nil else { return }
                saveEntry()
            }
            .accessibilityIdentifier("inspector.place.confidencePicker")

            if entryRejected {
                Text("Hmm, that was empty — try a town like Franklin, MA, or a region like Cape Cod.")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .accessibilityIdentifier("inspector.place.rejected")
            }

            statusLine
        }
        .padding(.vertical, 4)
    }

    // MARK: Status line

    @ViewBuilder
    private var statusLine: some View {
        switch record.userPlaceStatus {
        case .known:
            savedLabel(text: "Saved: \(record.userPlace ?? "") — you're sure",
                       icon: "checkmark.seal.fill", color: .accentColor)
        case .estimated:
            savedLabel(text: "Saved: \(record.userPlace ?? "") — best guess",
                       icon: "questionmark.circle", color: .secondary)
        case .unplaced:
            Text("No place yet — even \"Cape Cod\" or \"NH\" helps find this later.")
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
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inspector.place.status")
    }

    // MARK: Mutations

    private func saveEntry() {
        let trimmed = entryText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Emptying the field and hitting Save/Return is a clear.
        guard !trimmed.isEmpty else {
            if record.userPlace != nil { clearEntry() }
            return
        }
        guard let canonical = UserPlaceEntry.canonicalize(trimmed) else {
            entryRejected = true
            return
        }
        entryRejected = false
        entryText = canonical   // reflect the normalized form back
        record.userPlace = canonical
        record.userPlaceConfidence = (isKnown ? UserPlaceConfidence.known
                                              : UserPlaceConfidence.estimated).rawValue
        save()
    }

    private func clearEntry() {
        entryText = ""
        entryRejected = false
        record.userPlace = nil
        record.userPlaceConfidence = nil   // meaningless without a place
        save()
    }

    /// Explicit save through the normal catalog path: redraw this view,
    /// then let VideoScanModel's .videoScanCatalogMutated listener refresh
    /// this record's search-index entry, run the debounced catalog save,
    /// and (via the dossier-counts pass) refresh the place roster.
    private func save() {
        refreshTick &+= 1
        NotificationCenter.default.post(name: .videoScanCatalogMutated, object: record)
    }
}
