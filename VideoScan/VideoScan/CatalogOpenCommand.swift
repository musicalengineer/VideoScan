// CatalogOpenCommand.swift
// ⌘O in the Catalog opens the highlighted rows in the right player — the
// double-click gesture as a menu item (Rick 2026-09-26: "need a shortcut,
// cmd-o in catalog opens a file … the open, like a double-click, should
// try to know what player to use").
//
// Same routing story as ⌘⌫ (CatalogTrashCommand.swift): a Command-key
// combination is a KEY EQUIVALENT that AppKit offers to the menu bar
// before any view sees a keyDown, so the gesture has to be a real
// File ▸ Open item whose target is whatever catalog table currently has
// keyboard focus. The table publishes a `CatalogOpenSelection` as a
// FOCUSED value (never a scene value): a search field with focus keeps
// its own ⌘O, and the item is disabled until a table row is highlighted.
//
// ONE open path. The table's primaryAction (double-click / Return) and
// this menu item both end in `CatalogOpenAction.open`, which does the
// "looks moved" check per record and hands the rows to MediaOpener's
// smart chooser — QuickTime when the cataloged codecs guarantee picture
// AND sound there, VLC otherwise (MediaOpener.preferredPlayer). There is
// no second player policy in this file; it only says which one was used.
//
// (For Rick: `FocusedValueKey` ≈ a typed slot the focused view fills and
// the menu reads; nil when no catalog table has focus. The closure-taking
// overload of `open` is the test seam — dependency injection by function
// pointer, the way you'd pass callbacks into a C++ routine to keep the
// unit under test free of the real player launcher.)

import SwiftUI

/// What the focused catalog table offers the File menu: how many rows are
/// highlighted and the action that opens them.
struct CatalogOpenSelection {
    let count: Int
    let perform: () -> Void
}

struct CatalogOpenSelectionKey: FocusedValueKey {
    typealias Value = CatalogOpenSelection
}

extension FocusedValues {
    var catalogOpenSelection: CatalogOpenSelection? {
        get { self[CatalogOpenSelectionKey.self] }
        set { self[CatalogOpenSelectionKey.self] = newValue }
    }
}

/// The File ▸ Open item. Lives in its own View so `@FocusedValue` can be
/// read inside the Commands builder.
struct CatalogOpenMenuItem: View {
    @FocusedValue(\.catalogOpenSelection) private var selection

    var body: some View {
        Button(Self.title(count: selection?.count ?? 0)) {
            selection?.perform()
        }
        .keyboardShortcut("o", modifiers: .command)
        .disabled((selection?.count ?? 0) == 0)
        .help("Open the highlighted catalog rows the way a double-click does — QuickTime Player when the cataloged codecs play there with sound, VLC otherwise. Files on offline volumes are skipped.")
    }

    /// Plain "Open" for one row; the count when there are more. The title
    /// deliberately does NOT name the player: deciding it means reading
    /// every selected record on each menu build, and a select-all would
    /// make that O(records) work in a view body (the #104 class of bug).
    /// The console line written on Open says which player each file got.
    static func title(count: Int) -> String {
        count > 1 ? "Open \(count) Files" : "Open"
    }
}

/// The one function both gestures land in. Pure orchestration: pick the
/// selected rows out of the table in TABLE order, note any file that looks
/// moved (the Update Catalog banner), say what is about to happen on the
/// console, then launch. No file-system or app-launch code of its own.
enum CatalogOpenAction {

    /// Production wiring: the model's console, the model's looks-moved
    /// check, and MediaOpener's smart launch.
    @MainActor
    @discardableResult
    static func open(ids: Set<UUID>,
                     rows: [VideoRecord],
                     gesture: String,
                     model: VideoScanModel) -> [VideoRecord] {
        open(ids: ids, rows: rows, gesture: gesture, hasVLC: MediaOpener.hasVLC,
             log: { model.log($0) },
             noteMissing: { model.noteMissingFileForUserAction($0) },
             launch: { MediaOpener.open($0) })
    }

    /// The seam overload — every side effect injected. `noteMissing`
    /// returns true when the file is missing on a mounted volume (the
    /// signature `VideoScanModel.noteMissingFileForUserAction` has).
    /// Returns the records handed to `launch`, in table order.
    @MainActor
    @discardableResult
    static func open(ids: Set<UUID>,
                     rows: [VideoRecord],
                     gesture: String,
                     hasVLC: Bool,
                     log: (String) -> Void,
                     noteMissing: (VideoRecord) -> Bool,
                     launch: ([VideoRecord]) -> Void) -> [VideoRecord] {
        // BEGIN LINE discipline (same as ⌘⌫): an empty or stale selection
        // must not look like a dead shortcut. Say the gesture arrived,
        // then say why nothing followed.
        guard !ids.isEmpty else {
            log("Open (\(gesture)): nothing is selected — click a row first.")
            return []
        }
        // One pass over the table, not one search per id: a select-all
        // on a 100k-row catalog is O(n), not O(n·k).
        let targets = rows.filter { ids.contains($0.id) }
        guard !targets.isEmpty else {
            log("Open (\(gesture)): the \(ids.count) selected row(s) are no longer in the table — nothing to do.")
            return []
        }
        // "Looks moved" (Update Catalog, 2026-08-17): a file missing while
        // its volume is mounted → non-blocking banner offering Update
        // Catalog (once per volume per session). Never blocks the open of
        // the files that ARE there.
        var looksMoved = 0
        for r in targets where noteMissing(r) { looksMoved += 1 }
        var line = "Open (\(gesture)): \(targets.count) file(s) — \(playerSummary(targets, hasVLC: hasVLC))"
        if looksMoved > 0 {
            line += "; \(looksMoved) missing on a mounted volume (see the Update Catalog banner)"
        }
        log(line)
        launch(targets)
        return targets
    }

    /// "2 in QuickTime Player, 1 in VLC" — the same pure decision
    /// MediaOpener.open makes, counted so the console can say it. Cheap:
    /// three string compares per record, only for the rows being opened.
    static func playerSummary(_ records: [VideoRecord], hasVLC: Bool) -> String {
        var qt = 0, vlc = 0, other = 0
        for r in records {
            switch MediaOpener.preferredPlayer(for: r, hasVLC: hasVLC) {
            case .quickTime:     qt += 1
            case .vlc:           vlc += 1
            case .systemDefault: other += 1
            }
        }
        var parts: [String] = []
        if qt > 0 { parts.append("\(qt) in QuickTime Player") }
        if vlc > 0 { parts.append("\(vlc) in VLC") }
        if other > 0 { parts.append("\(other) in the default app") }
        return parts.joined(separator: ", ")
    }
}
