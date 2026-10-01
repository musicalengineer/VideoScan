// FamilyTreeDocumentsUI.swift
// The two views behind "Add document…" on a Family Tree person (Rick,
// 2026-09-20: birth / death / marriage certificates and other papers,
// PNG/JPG/PDF, stored "as such in the database"):
//
//   • FamilyDocumentAddSheet — kind picker, Choose file…, note, Add/Cancel.
//     The import runs through `FamilyAssetStore.importPersonDocument` off
//     the main actor; a refusal (read-only archive, not a PNG/JPG/PDF,
//     too large) is shown in the sheet in plain words.
//   • FamilyTreeDocumentsPanel — the "Documents" section of the inspector,
//     a person-records list (Rick, 2026-10-01): rows grouped Birth, Death,
//     Marriage, Military, Census, Other; each with a Quick Look thumbnail
//     (or the kind's symbol), the record's year and source site when it was
//     filed through Record Finder, date added, original name and note.
//     Clicking a row opens Quick Look with ALL the person's documents, so
//     the arrow keys walk through them; Show in Finder, Open and Remove
//     (confirmed; the file goes to Documents/.trash, never rm) stay on the
//     row. Under the list, one "Research" line: how many findings are
//     Confirmed, and a button to the existing Research pane.
//     Every row is a `PersonDocumentRow` — the document AND the person it
//     was read for — so Remove is bound to that owner, not to whoever is
//     selected when the dialog is confirmed (codex 1593 #9).
//
// Neither view touches the store in `body`: the panel is handed
// `model.selectedDocuments` (read once per selection), groups that short
// list (one person's documents — never the tree), and reads the person's
// research dossier in a `.task` off the main actor. The sheet reads
// nothing until Add is pressed.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// What the Add sheet is for. `Identifiable` so `.sheet(item:)` can drive
/// it (the item-binding form, per the chained-sheet note in memory).
struct FamilyDocumentAddTarget: Identifiable {
    /// The tree person id.
    let id: String
    let personName: String
    let assetPerson: FamilyAssetPerson
}

struct FamilyDocumentAddSheet: View {
    let target: FamilyDocumentAddTarget
    let onAdded: (PersonDocument) -> Void
    let onCancel: () -> Void

    @State private var kind: PersonDocumentKind = .birth
    @State private var chosenURL: URL?
    @State private var note = ""
    @State private var errorText: String?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a document for \(target.personName)")
                .font(.system(size: 15, weight: .semibold))

            // `Picker` with `.segmented` ≈ a radio group drawn as one bar;
            // `$kind` is the two-way binding to the @State storage.
            Picker("What is it?", selection: $kind) {
                ForEach(PersonDocumentKind.allCases, id: \.self) { kind in
                    Text(kind.shortLabel).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("tree.documents.kind")

            HStack(spacing: 10) {
                Button("Choose file…") { chooseFile() }
                    .accessibilityIdentifier("tree.documents.chooseFile")
                Text(chosenURL?.lastPathComponent ?? "PNG, JPG or PDF")
                    .font(.system(size: 12))
                    .foregroundStyle(chosenURL == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("tree.documents.chosenFile")
            }

            TextField("Note (where it came from, what it says…)", text: $note)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("tree.documents.note")

            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tree.documents.error")
            }

            Text("Filed as \(kind.displayName.lowercased()) beside \(target.personName)’s photos "
                 + "(People/…/Documents). Your GEDCOM is never changed.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("tree.documents.cancel")
                Button(isAdding ? "Adding…" : "Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(chosenURL == nil || isAdding)
                    .accessibilityIdentifier("tree.documents.confirmAdd")
            }
        }
        .padding(20)
        // Six kinds since 2026-10-01 (Military, Census): wide enough that
        // the segmented picker never truncates a label.
        .frame(width: 520)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .pdf]
        panel.prompt = "Choose"
        panel.message = "Choose a scanned certificate or document (PNG, JPG or PDF) for \(target.personName)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chosenURL = url
        errorText = nil
    }

    /// The import, off the main actor. Only `Sendable` values cross into
    /// the detached task (the URL, the kind, the note, the person and the
    /// archive configuration); the store is made inside it.
    private func add() {
        guard let source = chosenURL else { return }
        isAdding = true
        errorText = nil
        let kind = kind
        let note = note
        let person = target.assetPerson
        let configuration = FamilyAssetConfigurationCenter.shared.snapshot()
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<PersonDocument, Error> in
                let store = configuration.makeStore()
                do {
                    let folder = try store.folderForPhotoRequest(person: person)
                    let document = try store.importPersonDocument(
                        from: source, kind: kind, note: note, into: folder, for: person)
                    return .success(document)
                } catch {
                    return .failure(error)
                }
            }.value
            isAdding = false
            switch outcome {
            case .success(let document):
                onAdded(document)
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
    }
}

/// The inspector's "Documents" section. Rows are `PersonDocumentRow`s —
/// each carries the person it was read for, and Remove hands THAT row (not
/// "the selected person's document") to the model, which re-validates the
/// owner at confirmation (codex 1593 #9).
struct FamilyTreeDocumentsPanel: View {
    /// Same palette as the enclosing tree. Read from the environment
    /// rather than passed in: the parent sets `.preferredColorScheme`, so
    /// the scheme here is already the resolved one.
    @Environment(\.colorScheme) private var colorScheme
    private var palette: FamilyTreePalette {
        FamilyTreePalette.palette(for: colorScheme == .dark ? .dark : .light)
    }

    let documents: [PersonDocumentRow]
    /// True while the selected person's list is being read; the previous
    /// person's rows are already gone by then.
    let isLoading: Bool
    /// The last add/remove failure, shown under the list.
    let errorText: String?
    /// The person's research dossier key (FamilySearch ID or the `U-`
    /// fallback) when they may be researched; nil hides the Research line.
    var researchKey: String? = nil
    /// Where dossiers live; called once per load, inside the `.task`.
    var researchStore: () -> ResearchStore? = { nil }
    /// Bumped by the parent when the Research pane closes, so a verdict
    /// changed there is counted here.
    var researchRevision = 0
    let onAdd: () -> Void
    let onRemove: (PersonDocumentRow) -> Void
    /// Opens the existing Research pane for the selected person.
    var onOpenResearch: (() -> Void)? = nil

    @State private var removeCandidate: PersonDocumentRow?
    /// Years, sites and the confirmed count for the rows on screen.
    @State private var research = PersonDocumentsResearch.empty
    /// The Quick Look list's owner (a reference type, so it survives
    /// re-renders; `@State` keeps the same instance for the view's life).
    @State private var quickLook = DocumentQuickLookController()

    /// Rows past this many show the kind's symbol instead of a thumbnail
    /// (memory: ≤ 40 × ~64 KB).
    static let thumbnailLimit = 40

    /// What the research read depends on; a change re-runs the `.task`.
    private struct ResearchLoadKey: Equatable {
        let rowIDs: [UUID]
        let researchKey: String?
        let revision: Int
    }

    var body: some View {
        // One person's documents (a handful, ≤ a few hundred): grouping
        // here is O(rows), never O(tree).
        let groups = PersonDocumentsResearch.grouped(documents)
        let ordered = groups.flatMap(\.rows)
        // Row id → its place in the drawn order (Quick Look's start index).
        let position = Dictionary(ordered.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Documents")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !documents.isEmpty {
                    Text("\(documents.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    onAdd()
                } label: {
                    Image(systemName: "doc.badge.plus")
                }
                .buttonStyle(.plain)
                .masterOnly()
                .help("Add a birth, death, marriage, military or census record, or another document (also right-click the card)")
                .accessibilityIdentifier("tree.documents.add")
            }

            if isLoading && documents.isEmpty {
                Text("Reading documents…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("tree.documents.loading")
            } else if documents.isEmpty {
                Text("No documents filed yet — a birth or death certificate, a marriage record, a census page, a service record.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tree.documents.empty")
            } else {
                ForEach(groups) { group in
                    groupSection(group, ordered: ordered, position: position)
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tree.documents.error")
            }

            if researchKey != nil, let onOpenResearch {
                researchLine(onOpenResearch)
            }
        }
        .background(QuickLookAnchor(controller: quickLook).frame(width: 0, height: 0))
        // The dossier read, off the main actor; re-run when the rows, the
        // person or the pane's revision change. A stale result never lands:
        // `.task(id:)` cancels the previous run and we check before assigning.
        .task(id: ResearchLoadKey(rowIDs: documents.map(\.id), researchKey: researchKey,
                                  revision: researchRevision)) {
            let rows = documents
            let key = researchKey
            let store = key == nil ? nil : researchStore()
            let loaded = await Task.detached(priority: .utility) {
                PersonDocumentsResearch.load(rows: rows, researchKey: key, store: store)
            }.value
            if !Task.isCancelled { research = loaded }
        }
        // A different person (or a removal) while Quick Look shows the old
        // list: close it rather than show papers that are no longer here.
        .onChange(of: documents.map(\.id)) { _, _ in quickLook.closeIfShowing() }
        // `.confirmationDialog(…, presenting:)` ≈ a modal "are you sure"
        // that is shown while the optional is non-nil and hands the value
        // to its buttons. The value is the whole row, owner included.
        .confirmationDialog(
            "Remove \(removeCandidate?.document.kind.displayName.lowercased() ?? "document")?",
            isPresented: Binding(get: { removeCandidate != nil },
                                 set: { if !$0 { removeCandidate = nil } }),
            presenting: removeCandidate
        ) { row in
            Button("Remove \(row.document.originalFilename)", role: .destructive) {
                onRemove(row)
                removeCandidate = nil
            }
            .accessibilityIdentifier("tree.documents.confirmRemove")
            Button("Cancel", role: .cancel) { removeCandidate = nil }
        } message: { row in
            Text("The file moves to Documents/.trash beside \(row.owner.name)’s photos. Nothing is deleted.")
        }
    }

    // MARK: Groups and rows

    private func groupSection(_ group: PersonDocumentGroup, ordered: [PersonDocumentRow],
                              position: [UUID: Int]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.rows.count == 1 ? group.kind.shortLabel : "\(group.kind.shortLabel) (\(group.rows.count))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("tree.documents.group.\(group.kind.rawValue)")
            ForEach(group.rows) { row in
                documentRow(row, index: position[row.id] ?? 0, ordered: ordered)
            }
        }
    }

    private func documentRow(_ row: PersonDocumentRow, index: Int, ordered: [PersonDocumentRow]) -> some View {
        let document = row.document
        let details = research.details[document.id]
        return HStack(alignment: .top, spacing: 8) {
            PersonDocumentThumbnail(url: document.fileURL, kind: document.kind,
                                    wantsThumbnail: index < Self.thumbnailLimit)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(document.kind.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    if let year = details?.year {
                        Text(year)
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .accessibilityIdentifier("tree.documents.year")
                    }
                    Spacer(minLength: 4)
                    Text(FamilyAssetStore.displayBytes(document.byteCount))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(subtitle(document, site: details?.site))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(document.originalFilename)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !document.note.isEmpty {
                    Text(document.note)
                        .font(.system(size: 12))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(document.note)
                }
                HStack(spacing: 10) {
                    Button("Quick Look") { preview(index: index, ordered: ordered) }
                        .accessibilityIdentifier("tree.documents.quickLook")
                    Button("Show in Finder") {
                        if let url = document.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    .accessibilityIdentifier("tree.documents.reveal")
                    Button("Open") {
                        if let url = document.fileURL { NSWorkspace.shared.open(url) }
                    }
                    .accessibilityIdentifier("tree.documents.open")
                    Spacer()
                    Button("Remove…", role: .destructive) { removeCandidate = row }
                        .masterOnly()
                        .accessibilityIdentifier("tree.documents.remove")
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .disabled(document.fileURL == nil)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.overlayInk.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // The whole row is the click target for Quick Look; the link
        // buttons inside it still take their own clicks first.
        .contentShape(Rectangle())
        .onTapGesture { preview(index: index, ordered: ordered) }
        .help("Click to look at it (Quick Look) — ← → walk through all of this person’s documents")
        .accessibilityIdentifier("tree.documents.row")
    }

    /// "irishgenealogy.ie · added 1 Oct 2026" — the site only for a
    /// document filed through Record Finder.
    private func subtitle(_ document: PersonDocument, site: String?) -> String {
        let added = "added \(FamilyTreeNote.shortDate(document.addedAt))"
        guard let site else { return added.prefix(1).uppercased() + added.dropFirst() }
        return "\(site) · \(added)"
    }

    /// Quick Look on this row, with every document of the person (in the
    /// order drawn) behind the arrow keys. Rows without a file are skipped.
    private func preview(index: Int, ordered: [PersonDocumentRow]) {
        let reachable = ordered.enumerated().compactMap { offset, row in
            row.document.fileURL.map { (offset, $0) }
        }
        guard !reachable.isEmpty else { return }
        let start = reachable.firstIndex { $0.0 == index } ?? 0
        quickLook.show(reachable.map(\.1), at: start)
    }

    // MARK: Research line

    private func researchLine(_ open: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(Self.researchSummary(confirmed: research.confirmedFindings))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("tree.documents.researchCount")
            Spacer(minLength: 4)
            Button("Research…") { open() }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .help("Open the Research pane for this person")
                .accessibilityIdentifier("tree.documents.openResearch")
        }
        .padding(.top, 2)
    }

    /// "Research: 2 confirmed findings" / "Research: none confirmed yet".
    static func researchSummary(confirmed: Int) -> String {
        switch confirmed {
        case 0: return "Research: none confirmed yet"
        case 1: return "Research: 1 confirmed finding"
        default: return "Research: \(confirmed) confirmed findings"
        }
    }
}
