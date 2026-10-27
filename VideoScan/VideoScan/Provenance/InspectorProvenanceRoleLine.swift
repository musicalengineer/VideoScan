// InspectorProvenanceRoleLine.swift — the Inspector's "Role: …" line
// (Provenance ▸ Set Role). Truth rule (CLAUDE.md rule 1): the line is read
// from catalog.sqlite — the CURRENT `provenance_roles` row of the selected
// file's content (`ProvenanceRoleStore.readCurrent`, one index probe off the
// main actor) — every time the selection's content or the store's revision
// changes; never from a field on the record and never from the menu's map.
//
// Codex #156 F2: a finished read is kept WITH the key it was read for
// (digest + revision). It is shown only while that key is the current one;
// the moment the selection or the revision moves, the line says "Role: …"
// until the new read lands — never the previous content's role, never a
// guess. `lines` checks the digest too, so the pure rule alone holds it.
//
// (For Rick: `.task(id:)` ≈ start an async read when the key changes and
// cancel the previous one — a debounced fetch tied to the view's lifetime;
// the stored key is the cache tag that says which request a result answers.)

import SwiftUI
import VideoScanCore

struct InspectorProvenanceRoleLine: View {
    /// The selected file's whole-file digest (CatalogCommit.digest(of:)); nil = none yet.
    let digest: String?
    @ObservedObject var store: ProvenanceRoleStore
    /// The last finished read and the key it answered.
    @State private var completed: Completed?

    struct ReadKey: Equatable {
        let digest: String?
        let revision: Int
    }

    private struct Completed: Equatable {
        let key: ReadKey
        let reading: ProvenanceRoleStore.CurrentReading
    }

    /// The reading that may be shown for `key`: only one read FOR that key.
    static func shownReading(for key: ReadKey, completedKey: ReadKey?,
                             reading: ProvenanceRoleStore.CurrentReading?) -> ProvenanceRoleStore.CurrentReading? {
        completedKey == key ? reading : nil
    }

    /// The lines shown (pure; the truth tests read it). A reading for any
    /// other content than `digest` is treated as "still reading".
    static func lines(digest: String?, reading: ProvenanceRoleStore.CurrentReading?, now: Date = Date()) -> [String] {
        guard let digest else { return [ProvenanceRoleWords.noDigestLine] }
        guard let reading, reading.digest == digest.lowercased() else { return ["Role: …"] }
        switch reading {
        case .noRow: return [ProvenanceRoleWords.inspectorLine(nil, now: now)]
        case .unavailable(_, let why): return ["Role: not readable now (\(why))"]
        case .row(let row):
            let first = ProvenanceRoleWords.inspectorLine(row, now: now)
            return row.sourceNotInCatalog ? [first, ProvenanceRoleWords.sourceMissingLine] : [first]
        }
    }

    var body: some View {
        let key = ReadKey(digest: digest, revision: store.revision)
        let shown = Self.lines(digest: digest,
                               reading: Self.shownReading(for: key, completedKey: completed?.key, reading: completed?.reading))
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
        .task(id: key) {
            guard let digest = key.digest else { return }
            let now = await store.readCurrent(digest: digest)
            if !Task.isCancelled { completed = Completed(key: key, reading: now) }
        }
    }
}
