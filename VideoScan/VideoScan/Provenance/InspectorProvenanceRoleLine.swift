// InspectorProvenanceRoleLine.swift — the Inspector's "Role: …" line
// (Provenance ▸ Set Role). Truth rule (CLAUDE.md rule 1): the line is read
// from catalog.sqlite — the CURRENT `provenance_roles` row of the selected
// file's content (`ProvenanceRoleStore.readCurrent`, one index probe off the
// main actor) — every time the selection's content or the store's revision
// changes; never from a field on the record and never from the menu's map.
// While the read is in flight the line says so ("Role: …"), never a guess.
//
// (For Rick: `.task(id:)` ≈ start an async read when the key changes and
// cancel the previous one — a debounced fetch tied to the view's lifetime.)

import SwiftUI
import VideoScanCore

struct InspectorProvenanceRoleLine: View {
    /// The selected file's whole-file digest (CatalogCommit.digest(of:)); nil = none yet.
    let digest: String?
    @ObservedObject var store: ProvenanceRoleStore
    @State private var reading: ProvenanceRoleStore.CurrentReading?

    private struct ReadKey: Equatable {
        let digest: String?
        let revision: Int
    }

    /// The lines shown (pure; the truth tests read it).
    static func lines(digest: String?, reading: ProvenanceRoleStore.CurrentReading?, now: Date = Date()) -> [String] {
        guard digest != nil else { return [ProvenanceRoleWords.noDigestLine] }
        switch reading {
        case nil: return ["Role: …"]
        case .none?: return [ProvenanceRoleWords.inspectorLine(nil, now: now)]
        case .unavailable(let why)?: return ["Role: not readable now (\(why))"]
        case .row(let row)?:
            let first = ProvenanceRoleWords.inspectorLine(row, now: now)
            return row.sourceNotInCatalog ? [first, ProvenanceRoleWords.sourceMissingLine] : [first]
        }
    }

    var body: some View {
        let shown = Self.lines(digest: digest, reading: reading)
        VStack(alignment: .leading, spacing: 2) {
            Text(shown[0])
                .font(.callout)
                .textSelection(.enabled)
            ForEach(shown.dropFirst(), id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityIdentifier("catalog.inspector.provenanceRole")
        .task(id: ReadKey(digest: digest, revision: store.revision)) {
            reading = nil
            guard let digest else { return }
            let now = await store.readCurrent(digest: digest)
            if !Task.isCancelled { reading = now }
        }
    }
}
