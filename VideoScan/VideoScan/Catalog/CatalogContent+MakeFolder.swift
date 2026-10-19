// CatalogContent+MakeFolder.swift
// "Make Folder…" (Rick 2026-10-19) — two doors, ONE path:
//   • the focus banner's button: the banner's file set ("Thanksgiving 1984
//     (28 files)") — only when the banner shows a NAMED set, not a pair or
//     one file's copies;
//   • the row menu's "New Folder with Selection (N Items)…" (Finder's own
//     words): the selected rows ON SCREEN (`displayedIDs`, the one rule
//     every row action reads — in the folder view a collapsed folder's
//     member never counts; in the linear table it is the selection).
// Both call `makeFolder(name:recordIDs:)`, which builds the draft
// (EventsFolderDraft — pure) and presents the one sheet (.sheet(item:)).
// Make Folder confirms an event through `EventsDecisionStore.confirm` (the
// Events page's own write — catalog.sqlite once that is the authority),
// of the KIND Rick picks (event / person / other, 2026-10-19), then Show ▸
// As folders goes on, the focus is cleared, and the new folder is selected
// with its triangle open as soon as the join shows it
// (`pendingFolderReveal`). One folder line naming every file (catalog.log;
// 20 on the console) and one counts-only Events line.
//
// (Swift extension ≈ C++ partial class via free member functions; the
// sheet's @State lives on CatalogContent in CatalogHelpers.swift.)

import SwiftUI

/// The sheet's payload. A new id per open, so `.sheet(item:)` always
/// presents a fresh sheet (≈ a nullable handle: non-nil = shown).
struct MakeFolderRequest: Identifiable {
    let id = UUID()
    let draft: EventsFolderDraft
    /// The files the sheet was opened on (the log line names them).
    var recordIDs: Set<UUID> = []
}

extension CatalogContent {

    // MARK: - The one path

    /// Both doors land here: the draft for these records, in the sheet.
    /// O(n log n), n = ids; an event handler, never a body.
    func makeFolder(name: String, recordIDs: Set<UUID>) {
        guard !recordIDs.isEmpty else { return }
        let draft = EventsFolderDraft(name: name, recordIDs: recordIDs, record: { model.record(forID: $0) })
        makeFolderRequest = MakeFolderRequest(draft: draft, recordIDs: recordIDs)
    }

    /// The sheet's Make Folder. The store says no (read-only, a save
    /// refused) → nothing changes and the log says why.
    func commitMakeFolder(_ draft: EventsFolderDraft, recordIDs: Set<UUID> = []) {
        let store = EventsDecisionStore.shared
        guard let event = draft.make(in: store) else {
            model.eventsNote("Make Folder did nothing — \(store.problem ?? draft.refusal ?? "the store refused")")
            return
        }
        let keys = Set(draft.members.ranges.map(\.contentKey))
        let files = recordIDs.compactMap { model.record(forID: $0) }
            .filter { EventsFolderMembers.contentKey($0).map(keys.contains) ?? false }
        EventsFolderLog.say(EventsFolderLog.created(EventsNaming.folderTitle(event.name), kind: event.kind,
                                                    files: EventsFolderLog.filenames(files)), model: model)
        EventsStore.shared.eventConfirmedElsewhere(model: model)
        // Reveal from the top level: a scope on another folder would hide it.
        tableState.pendingFolderReveal = event.id
        setFolderScope(nil)
        onMadeFolder?()
        // Counts only — a log line never carries an event's name.
        let m = draft.members
        model.eventsNote("made a folder of \(m.ranges.count) recording\(m.ranges.count == 1 ? "" : "s") from "
                         + "\(m.fileCount) file\(m.fileCount == 1 ? "" : "s") (\(m.copies) cop\(m.copies == 1 ? "y" : "ies") "
                         + "folded in, \(m.skipped) skipped) — Show ▸ As folders is on")
    }

    /// A folder made a moment ago that the level now shows: select it and
    /// twist it open (before the caller counts the displayed rows). True
    /// when it was revealed. Called from `rebuildFolderRows`.
    func takePendingFolderReveal(in level: FootageFolderLevel.Level) -> Bool {
        guard tableState.folderKeyMirror.isOn, let id = tableState.pendingFolderReveal,
              level.folderIDs.contains(id) else { return false }
        tableState.pendingFolderReveal = nil
        tableState.expandedFolderIDs.insert(id)
        selectedIDs = [id]
        return true
    }

    /// Triage ▸ Events' "Show in Catalog" (`model.pendingCatalogFolderReveal`)
    /// joins the same reveal as Make Folder: the id becomes this table's
    /// `pendingFolderReveal`, from the top level. Waits (leaves the request
    /// on the model) while the folder view is off — turning it on calls
    /// this again (`footageFoldersOptionChanged`). A folder the top level
    /// already shows is revealed now: a repeat compose publishes nothing.
    func takeFolderRevealRequest() {
        guard tableState.folderKeyMirror.isOn, let id = model.pendingCatalogFolderReveal else { return }
        model.pendingCatalogFolderReveal = nil
        tableState.pendingFolderReveal = id
        if tableState.folderScope != nil {
            setFolderScope(nil)   // the top level's display lands and completes the reveal
            return
        }
        guard takePendingFolderReveal(in: tableState.folderLevel) else {
            refreshFolderDisplay()
            return
        }
        tableState.folderRecordIDs = tableState.folderLevel.recordIDs(expanded: tableState.expandedFolderIDs)
        CatalogTableReveal.scrollSelectionIntoView()
    }

    // MARK: - The doors

    /// The banner's door: its file set, under its label.
    var makeFolderBannerButton: some View {
        MakeFolderBannerButton(isNamedSet: focusIsNamedSet) {
            makeFolder(name: focusLabel, recordIDs: filterByIDs)
        }
    }

    /// The row menu's door (the `.describe` group, pure-active
    /// selections): the rows the menu already resolved — `shown`
    /// (displayedIDs) — never the raw selection.
    @ViewBuilder
    func newFolderWithSelectionItem(selection: CatalogRowMenuSelection) -> some View {
        let ids = Set(selection.selected.map(\.id))
        Button(MakeFolderWords.newFolderWithSelection(ids.count)) {
            makeFolder(name: "", recordIDs: ids)
        }
        .disabled(ids.isEmpty)
        .accessibilityIdentifier("catalog.row.newFolderWithSelection")
    }
}

// MARK: - Words (pure)

enum MakeFolderWords {
    static let button = "Make Folder…"
    static let sheetTitle = "New Folder"
    static let make = "Make Folder"
    static let namePrompt = "Folder name"
    static let kindLabel = "Kind"
    static let kindHelp = "Event (blue): an occasion. Person (green): one person's footage. Other (grey): anything else. Right-click the folder later to change it."
    static let notNamedSetHelp = "Make Folder works on a named set of files — from Triage, Steward or an audit — not on an A/V pair, one file's copies or a single navigation."
    static let help = "Make these files one folder (a confirmed event). Copies fold under their recording."

    /// Finder's own wording: "New Folder with Selection (3 Items)".
    static func newFolderWithSelection(_ n: Int) -> String {
        "New Folder with Selection (\(n) Item\(n == 1 ? "" : "s"))…"
    }

    static func readOnlyHelp(_ why: String) -> String { "Folders can't be saved right now: \(why)." }

    /// "28 files → 3 recordings · 24 copies fold in · 1 skipped (no full content hash yet)".
    static func summary(_ m: EventsFolderMembers) -> String {
        var parts = ["\(m.fileCount) file\(m.fileCount == 1 ? "" : "s") → \(m.ranges.count) recording\(m.ranges.count == 1 ? "" : "s")"]
        if m.copies > 0 { parts.append("\(m.copies) cop\(m.copies == 1 ? "y folds" : "ies fold") in") }
        if m.skipped > 0 { parts.append("\(m.skipped) skipped (no full content hash yet, or removed / set aside)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The banner button

/// Its own view so it alone observes the decision store (≈ a small
/// observer): a load or a refusal re-draws this button, not the Catalog.
struct MakeFolderBannerButton: View {
    let isNamedSet: Bool
    let action: () -> Void
    @ObservedObject private var store = EventsDecisionStore.shared

    /// nil = enabled. Not loaded yet is NOT a refusal: the sheet loads it.
    private var refusal: String? {
        if !isNamedSet { return MakeFolderWords.notNamedSetHelp }
        if store.hasLoaded, let why = store.writeRefusal { return MakeFolderWords.readOnlyHelp(why) }
        return nil
    }

    var body: some View {
        Button(MakeFolderWords.button, action: action)
            .buttonStyle(.bordered)
            .font(.system(size: 11))
            .disabled(refusal != nil)
            .help(refusal ?? MakeFolderWords.help)
            .accessibilityIdentifier("catalog.focus.makeFolder")
    }
}

// MARK: - The sheet

struct MakeFolderSheet: View {
    let request: MakeFolderRequest
    let onMake: (EventsFolderDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = EventsDecisionStore.shared
    @State private var name: String

    init(request: MakeFolderRequest, onMake: @escaping (EventsFolderDraft) -> Void) {
        self.request = request
        self.onMake = onMake
        // `_name` is the @State's storage ≈ initialising a member in a C++ ctor's init list.
        _name = State(initialValue: request.draft.name)
        _kind = State(initialValue: request.draft.kind)
    }

    @State private var kind: FolderKind

    private var draft: EventsFolderDraft {
        var d = request.draft
        d.name = name
        d.kind = kind
        return d
    }

    /// Why Make Folder is greyed: the draft's own reason, else the store's.
    private var refusal: String? {
        draft.refusal ?? store.writeRefusal.map(MakeFolderWords.readOnlyHelp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(MakeFolderWords.sheetTitle).font(.headline)
            TextField(MakeFolderWords.namePrompt, text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
                .onSubmit(make)
            Picker(MakeFolderWords.kindLabel, selection: $kind) {
                ForEach(FolderKind.allCases) { k in Text(k.title).tag(k) }
            }
            .pickerStyle(.segmented)
            .help(MakeFolderWords.kindHelp)
            .accessibilityIdentifier("catalog.makeFolder.kind")
            Text(MakeFolderWords.summary(request.draft.members))
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let refusal, !name.trimmingCharacters(in: .whitespaces).isEmpty || request.draft.members.ranges.isEmpty {
                Text(refusal).font(.caption).foregroundColor(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(MakeFolderWords.make, action: make)
                    .keyboardShortcut(.defaultAction)
                    .disabled(refusal != nil)
                    .help(refusal ?? MakeFolderWords.help)
            }
        }
        .padding(20)
        .task {
            // The Catalog may open before anything loaded Rick's decisions:
            // a write before the load is refused (it would publish an empty
            // store over his file), so load first. Off-main inside the store.
            if !store.hasLoaded { await store.load() }
        }
    }

    private func make() {
        guard refusal == nil else { return }
        onMake(draft)
        dismiss()
    }
}
