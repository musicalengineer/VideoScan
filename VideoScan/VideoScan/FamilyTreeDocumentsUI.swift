// FamilyTreeDocumentsUI.swift
// The two views behind "Add document…" on a Family Tree person (Rick,
// 2026-09-20: birth / death / marriage certificates and other papers,
// PNG/JPG/PDF, stored "as such in the database"):
//
//   • FamilyDocumentAddSheet — kind picker, Choose file…, note, Add/Cancel.
//     The import runs through `FamilyAssetStore.importPersonDocument` off
//     the main actor; a refusal (read-only archive, not a PNG/JPG/PDF,
//     too large) is shown in the sheet in plain words.
//   • FamilyTreeDocumentsPanel — the "Documents" section of the inspector:
//     kind · date added · original name · note, with Open, Show in Finder
//     and Remove (confirmed; the file goes to Documents/.trash, never rm).
//
// Neither view touches the store in `body`: the panel is handed
// `model.selectedDocuments` (read once per selection), and the sheet reads
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
        .frame(width: 440)
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

/// The inspector's "Documents" section.
struct FamilyTreeDocumentsPanel: View {
    /// Same palette as the enclosing tree. Read from the environment
    /// rather than passed in: the parent sets `.preferredColorScheme`, so
    /// the scheme here is already the resolved one.
    @Environment(\.colorScheme) private var colorScheme
    private var palette: FamilyTreePalette {
        FamilyTreePalette.palette(for: colorScheme == .dark ? .dark : .light)
    }

    let documents: [PersonDocument]
    /// The last add/remove failure, shown under the list.
    let errorText: String?
    let onAdd: () -> Void
    let onRemove: (PersonDocument) -> Void

    @State private var removeCandidate: PersonDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Documents")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onAdd()
                } label: {
                    Image(systemName: "doc.badge.plus")
                }
                .buttonStyle(.plain)
                .masterOnly()
                .help("Add a birth, death or marriage certificate, or another document (also right-click the card)")
                .accessibilityIdentifier("tree.documents.add")
            }

            if documents.isEmpty {
                Text("No documents filed yet — a birth or death certificate, a marriage record, a scanned letter.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tree.documents.empty")
            } else {
                ForEach(documents) { document in
                    row(document)
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tree.documents.error")
            }
        }
        // `.confirmationDialog(…, presenting:)` ≈ a modal "are you sure"
        // that is shown while the optional is non-nil and hands the value
        // to its buttons.
        .confirmationDialog(
            "Remove \(removeCandidate?.kind.displayName.lowercased() ?? "document")?",
            isPresented: Binding(get: { removeCandidate != nil },
                                 set: { if !$0 { removeCandidate = nil } }),
            presenting: removeCandidate
        ) { document in
            Button("Remove \(document.originalFilename)", role: .destructive) {
                onRemove(document)
                removeCandidate = nil
            }
            .accessibilityIdentifier("tree.documents.confirmRemove")
            Button("Cancel", role: .cancel) { removeCandidate = nil }
        } message: { _ in
            Text("The file moves to Documents/.trash beside this person’s photos. Nothing is deleted.")
        }
    }

    private func row(_ document: PersonDocument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(document.kind.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Text("· \(FamilyTreeNote.shortDate(document.addedAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(FamilyAssetStore.displayBytes(document.byteCount))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Text(document.originalFilename)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if !document.note.isEmpty {
                Text(document.note)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Open") {
                    if let url = document.fileURL { NSWorkspace.shared.open(url) }
                }
                .accessibilityIdentifier("tree.documents.open")
                Button("Show in Finder") {
                    if let url = document.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .accessibilityIdentifier("tree.documents.reveal")
                Spacer()
                Button("Remove…", role: .destructive) { removeCandidate = document }
                    .masterOnly()
                    .accessibilityIdentifier("tree.documents.remove")
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .disabled(document.fileURL == nil)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.overlayInk.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("tree.documents.row")
    }
}
