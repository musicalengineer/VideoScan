// CatalogContent+FolderLabels.swift
// Folders as LABELS (Rick 2026-10-19: "Finder's handling, Photos albums'
// meaning" — a folder is a confirmed event; one file may be in many):
//
//   files → a folder   ONE path (`applyFolderMembership`) for a drag onto a
//                      folder, "Add to Folder ▸" and "Move to Folder ▸";
//                      "Remove from <Folder>" is its mirror. The plans are
//                      pure (EventsFolderDrop / EventsFolderRemoval); the
//                      store writes them to catalog.sqlite in one commit.
//   a folder itself    Rename…, Folder Kind ▸ Event / Person / Other, and
//                      Delete Folder… (the label only — the files stay; a
//                      confirmation names how many).
//   the inspector      a selected folder's facts, computed here once per
//                      selection / revision (FolderInspectorFacts).
// Every change says one line through the one sink (EventsFolderLog: every
// filename in catalog.log, 20 on the console).
//
// Event handlers and menu builders only — nothing here runs in a body
// except the menus' O(folders) lists, built when the menu opens.
//
// (Swift extension ≈ C++ partial class via free member functions.)

import SwiftUI

/// Rename…'s payload (≈ a nullable handle: non-nil = the sheet is shown).
struct FolderRenameRequest: Identifiable, Equatable {
    let id: UUID
    let name: String
}

/// Delete Folder…'s payload: what the confirmation names.
struct FolderDeleteRequest: Identifiable, Equatable {
    let id: UUID
    let name: String
    let files: Int
}

/// One folder in an "Add to / Move to Folder ▸" menu.
struct FolderChoice: Identifiable, Equatable {
    let id: UUID
    let title: String
    let kind: FolderKind

    /// Every live folder, by title. O(folders).
    @MainActor
    static func all(in store: EventsDecisionStore) -> [FolderChoice] {
        store.snapshot().liveEvents
            .map { FolderChoice(id: $0.id, title: EventsNaming.folderTitle($0.name), kind: $0.kind) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

extension CatalogContent {

    private var folderStore: EventsDecisionStore { .shared }

    private func folderTitle(_ id: UUID) -> String {
        folderStore.event(id: id).map { EventsNaming.folderTitle($0.name) } ?? "a folder"
    }

    // MARK: - Files into, out of, between folders

    /// THE membership path. Refused / nothing to do → one note, nothing
    /// changes. Otherwise one commit, the dropped rows selected once the
    /// folder shows them, one folder line and one Events line.
    func applyFolderMembership(target: UUID, recordIDs: Set<UUID>, mode: EventsFolderDrop.Mode, gesture: String) {
        let store = folderStore
        let drop = EventsFolderDrop(target: target, recordIDs: recordIDs, record: { model.record(forID: $0) },
                                    decisions: store.snapshot(), mode: mode)
        if let why = drop.refusal {
            model.eventsNote("\(gesture) did nothing — \(why)")
            return
        }
        guard !drop.isNoOp else { return }   // already there (or nothing can join): nothing
        guard drop.apply(in: store) else {
            model.eventsNote("\(gesture) did nothing — \(store.problem ?? "the folder store refused")")
            return
        }
        EventsStore.shared.eventConfirmedElsewhere(model: model)
        let moved = Set(drop.movingFrom.values.flatMap { $0.map(\.contentKey) })
        let changedKeys = drop.addedKeys.union(moved)
        let changed = recordIDs.compactMap { model.record(forID: $0) }
            .filter { EventsFolderMembers.contentKey($0).map(changedKeys.contains) ?? false }
        tableState.pendingDropSelection = FolderDropLanding(folder: drop.target, recordIDs: Set(changed.map(\.id)))
        let names = EventsFolderLog.filenames(changed)
        let kind = store.event(id: drop.target)?.kind ?? .event
        switch drop.mode {
        case .add:
            EventsFolderLog.say(EventsFolderLog.added(to: folderTitle(drop.target), kind: kind, files: names), model: model)
        case .move(let from):
            EventsFolderLog.say(EventsFolderLog.moved(from: folderTitle(from), to: folderTitle(drop.target), files: names), model: model)
        }
        model.eventsNote(FolderDropWords.logLine(drop))
    }

    /// "Remove from <Folder>": the content leaves that folder only.
    func removeFromFolder(_ folder: UUID, recordIDs: Set<UUID>) {
        let store = folderStore
        let removal = EventsFolderRemoval(folder: folder, recordIDs: recordIDs, record: { model.record(forID: $0) },
                                          decisions: store.snapshot())
        guard !removal.isNoOp else { return }
        guard removal.apply(in: store) else {
            model.eventsNote("Remove from Folder did nothing — \(store.problem ?? "the folder store refused")")
            return
        }
        EventsStore.shared.eventConfirmedElsewhere(model: model)
        let keys = removal.leavingKeys
        let changed = recordIDs.compactMap { model.record(forID: $0) }
            .filter { EventsFolderMembers.contentKey($0).map(keys.contains) ?? false }
        EventsFolderLog.say(EventsFolderLog.removed(from: folderTitle(removal.folder), files: EventsFolderLog.filenames(changed)),
                            model: model)
    }

    // MARK: - The folder itself

    /// Every filename in a folder now (the log lines of a rename, a kind
    /// change, a delete). O(records), in the handler.
    private func filenames(inFolder id: UUID) -> [String] {
        let keys = Set(folderStore.snapshot().members(of: id).map(\.contentKey))
        return EventsFolderLog.filenames(of: keys, in: model.records)
    }

    func renameFolder(_ id: UUID, to name: String) {
        let store = folderStore
        let old = folderTitle(id)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != store.event(id: id)?.name else { return }
        guard store.renameEvent(id, to: trimmed) else {
            model.eventsNote("Rename did nothing — \(store.problem ?? "the folder store refused")")
            return
        }
        EventsStore.shared.eventConfirmedElsewhere(model: model)
        EventsFolderLog.say(EventsFolderLog.renamed(from: old, to: folderTitle(id), kind: store.event(id: id)?.kind ?? .event,
                                                    files: filenames(inFolder: id)), model: model)
    }

    func setFolderKind(_ id: UUID, _ kind: FolderKind) {
        let store = folderStore
        guard let old = store.event(id: id)?.kind, old != kind else { return }
        guard store.setKind(id, kind) else {
            model.eventsNote("Folder Kind did nothing — \(store.problem ?? "the folder store refused")")
            return
        }
        EventsFolderLog.say(EventsFolderLog.kindChanged(folderTitle(id), from: old, to: kind, files: filenames(inFolder: id)),
                            model: model)
    }

    func deleteFolder(_ id: UUID) {
        let store = folderStore
        let title = folderTitle(id)
        let kind = store.event(id: id)?.kind ?? .event
        let names = filenames(inFolder: id)
        guard store.deleteFolder(id) else {
            model.eventsNote("Delete Folder did nothing — \(store.problem ?? "the folder store refused")")
            return
        }
        EventsStore.shared.eventConfirmedElsewhere(model: model)
        if tableState.folderScope == .event(id) { setFolderScope(nil) }
        EventsFolderLog.say(EventsFolderLog.deleted(title, kind: kind, files: names), model: model)
    }

    // MARK: - Menus

    /// A folder row's menu: Open, Rename…, Folder Kind ▸, Delete Folder….
    @ViewBuilder
    func folderRowMenu(_ id: UUID) -> some View {
        let store = folderStore
        let refusal = store.writeRefusal
        let current = store.event(id: id)?.kind ?? .event
        Button(FootageFolderWords.openFolder) { enterFolder(id) }
        Button(FootageFolderWords.renameFolder) {
            tableState.folderRenameRequest = FolderRenameRequest(id: id, name: store.event(id: id)?.name ?? folderTitle(id))
        }
        .disabled(refusal != nil)
        Menu(FootageFolderWords.folderKindMenu) {
            ForEach(FolderKind.allCases) { kind in
                Button { setFolderKind(id, kind) } label: {
                    if kind == current { Label(kind.title, systemImage: "checkmark") } else { Text(kind.title) }
                }
            }
        }
        .disabled(refusal != nil)
        Divider()
        Button(FootageFolderWords.deleteFolder, role: .destructive) {
            let files = model.footageFolders.index.folders[id]?.summary.files ?? store.snapshot().members(of: id).count
            tableState.folderDeleteRequest = FolderDeleteRequest(id: id, name: folderTitle(id), files: files)
        }
        .disabled(refusal != nil)
        .accessibilityIdentifier("catalog.folder.delete")
    }

    /// The file rows' folder items: Add to Folder ▸ always; Move to Folder ▸
    /// and Remove from <Folder> when the rows are seen inside a folder.
    @ViewBuilder
    func folderMembershipItems(recordIDs: Set<UUID>, inFolder folder: UUID?) -> some View {
        let choices = FolderChoice.all(in: folderStore)
        let refusal = folderStore.writeRefusal
        if !recordIDs.isEmpty {
            Divider()
            Menu(FootageFolderWords.addToFolder) {
                ForEach(choices) { f in
                    Button(f.title) { applyFolderMembership(target: f.id, recordIDs: recordIDs, mode: .add, gesture: "Add to Folder") }
                }
                if choices.isEmpty { Text(FootageFolderWords.noOtherFolders) }
            }
            .disabled(refusal != nil)
            .help(refusal ?? FootageFolderWords.addHelp)
            .accessibilityIdentifier("catalog.row.addToFolder")
            if let folder {
                let others = choices.filter { $0.id != folder }
                Menu(FootageFolderWords.moveToFolder) {
                    ForEach(others) { f in
                        Button(f.title) {
                            applyFolderMembership(target: f.id, recordIDs: recordIDs, mode: .move(from: folder), gesture: "Move to Folder")
                        }
                    }
                    if others.isEmpty { Text(FootageFolderWords.noOtherFolders) }
                }
                .disabled(refusal != nil)
                .help(refusal ?? FootageFolderWords.moveHelp)
                .accessibilityIdentifier("catalog.row.moveToFolder")
                Button(FootageFolderWords.removeFromFolder(folderTitle(folder))) { removeFromFolder(folder, recordIDs: recordIDs) }
                    .disabled(refusal != nil)
                    .help(refusal ?? FootageFolderWords.removeHelp)
                    .accessibilityIdentifier("catalog.row.removeFromFolder")
            }
        }
    }

    // MARK: - The inspector

    /// One selected folder → its facts; anything else → none. Called from
    /// the selection handler and whenever the folder rows are rebuilt.
    func refreshFolderInspector() {
        guard selectedIDs.count == 1, let id = selectedIDs.first, tableState.folderIDs.contains(id),
              let event = folderStore.event(id: id) else {
            if tableState.folderInspector != nil { tableState.folderInspector = nil }
            return
        }
        let index = model.footageFolders.index
        let folder = index.folders[id]
        var members: [FolderInspectorFacts.Member] = []
        for fi in folder?.families ?? [] {
            for m in index.families[fi].members {
                guard let rec = model.record(forID: m.id), !rec.isPurged, !rec.isSetAside, !rec.isSuperseded else { continue }
                let date = index.keysOf[m.id]?.date
                members.append(FolderInspectorFacts.Member(
                    contentKey: VideoScanModel.eventsContentKey(rec), sizeBytes: rec.sizeBytes, durationSeconds: rec.durationSeconds,
                    date: date.flatMap { $0 > .distantPast ? $0 : nil }, volume: rec.volumeName,
                    isOnline: VolumeReachability.isReachable(path: rec.fullPath)))
            }
        }
        let facts = FolderInspectorFacts(event: event, title: folder?.title ?? folderTitle(id), members: members)
        if facts != tableState.folderInspector { tableState.folderInspector = facts }
    }
}

// MARK: - The sheets (hosted on the folder table)

/// Rename… and Delete Folder… for the folder table. A modifier, so the
/// table's builder does not grow two more presentations inline.
struct FolderLabelPresentations: ViewModifier {
    @Binding var rename: FolderRenameRequest?
    @Binding var delete: FolderDeleteRequest?
    let onRename: (UUID, String) -> Void
    let onDelete: (UUID) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $rename) { request in
                RenameFolderSheet(request: request, onRename: onRename)
            }
            .alert(delete.map { FootageFolderWords.deleteTitle($0.name) } ?? "",
                   isPresented: Binding(get: { delete != nil }, set: { if !$0 { delete = nil } }),
                   presenting: delete) { request in
                Button(FootageFolderWords.deleteButton, role: .destructive) { onDelete(request.id) }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text(FootageFolderWords.deleteMessage(files: request.files))
            }
    }
}

struct RenameFolderSheet: View {
    let request: FolderRenameRequest
    let onRename: (UUID, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(request: FolderRenameRequest, onRename: @escaping (UUID, String) -> Void) {
        self.request = request
        self.onRename = onRename
        // `_name` is the @State's storage ≈ initialising a member in a C++ ctor's init list.
        _name = State(initialValue: request.name)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(FootageFolderWords.renameTitle).font(.headline)
            TextField(MakeFolderWords.namePrompt, text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
                .onSubmit(commitRename)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(FootageFolderWords.renameButton, action: commitRename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
    }

    private func commitRename() {
        guard !trimmed.isEmpty else { return }
        onRename(request.id, trimmed)
        dismiss()
    }
}
