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
// A LARGE selection asks first (GH #203, night hardening 2026-09-27):
// ⌘A ⌘O on a 100k catalog handed ~40k files to QuickTime and ~60k to VLC
// with no question asked. Above `confirmThreshold` rows the action asks
// Finder's question — "Open 3,412 files?" (Open / Cancel) — BEFORE any
// looks-moved check or launch, so Cancel costs nothing and opens nothing.
// The question is an injected closure like every other side effect; the
// production wiring shows an NSAlert, tests answer it.
//
// Main-actor cost, documented rather than moved (GH #203 second half):
// after the user says Open, each row still gets up to two stat-class
// checks on the main actor — one in `noteMissingFileForUserAction` and one
// in MediaOpener's reachability filter. Neither moves off-main cheaply:
// the looks-moved check mutates model state (the per-volume debounce and
// the banner) and MediaOpener's app launch wants the main thread. Under
// the confirmation, that cost is only ever paid for a selection the user
// explicitly asked to open, and the 100k scale test pins the pass itself
// at well under a second with the checks stubbed.
//
// (For Rick: `FocusedValueKey` ≈ a typed slot the focused view fills and
// the menu reads; nil when no catalog table has focus. The closure-taking
// overload of `open` is the test seam — dependency injection by function
// pointer, the way you'd pass callbacks into a C++ routine to keep the
// unit under test free of the real player launcher.)

import AppKit
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
             confirm: { askToOpen($0) },
             noteMissing: { model.noteMissingFileForUserAction($0) },
             launch: { MediaOpener.open($0) })
    }

    /// Finder's rule: opening this many files at once asks first. At or
    /// below it (the ordinary double-click on a handful) nothing asks.
    static let confirmThreshold = 20

    /// Does opening `count` files need the user's yes?
    static func needsConfirmation(count: Int) -> Bool {
        count > confirmThreshold
    }

    /// "Open 3,412 files?" — grouped for the reader's locale.
    static func confirmationTitle(count: Int, locale: Locale = .current) -> String {
        "Open \(count.formatted(.number.locale(locale))) files?"
    }

    /// The production question: a modal alert, Open / Cancel, Cancel the
    /// default for Escape. Returns true only for Open.
    @MainActor
    private static func askToOpen(_ targets: [VideoRecord]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = confirmationTitle(count: targets.count)
        alert.informativeText = "Each file opens in a player window — by codec: \(playerSummary(targets, hasVLC: MediaOpener.hasVLC))."
        alert.addButton(withTitle: "Open")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The seam overload — every side effect injected. `confirm` is asked
    /// only when more than `confirmThreshold` rows would open, with the
    /// rows in table order; false opens nothing. `noteMissing` returns
    /// true when the file is missing on a mounted volume (the signature
    /// `VideoScanModel.noteMissingFileForUserAction` has).
    /// Returns the records handed to `launch`, in table order.
    @MainActor
    @discardableResult
    static func open(ids: Set<UUID>,
                     rows: [VideoRecord],
                     gesture: String,
                     hasVLC: Bool,
                     log: (String) -> Void,
                     confirm: ([VideoRecord]) -> Bool,
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
        // Ask BEFORE any per-row stat or launch: Cancel costs nothing.
        if needsConfirmation(count: targets.count), !confirm(targets) {
            log("Open (\(gesture)): cancelled — \(targets.count) file(s) selected, nothing opened.")
            return []
        }
        // "Looks moved" (Update Catalog, 2026-08-17): a file missing while
        // its volume is mounted → non-blocking banner offering Update
        // Catalog (once per volume per session). Never blocks the open of
        // the files that ARE there.
        var looksMoved = 0
        for r in targets where noteMissing(r) { looksMoved += 1 }
        var line = "Open (\(gesture)): \(targets.count) file(s) — by codec: \(playerSummary(targets, hasVLC: hasVLC)) (offline files are skipped by the opener)"
        if looksMoved > 0 {
            line += "; \(looksMoved) missing on a mounted volume (see the Update Catalog banner)"
        }
        log(line)
        launch(targets)
        return targets
    }

    /// "2 for QuickTime Player, 1 for VLC" — the codec-based PREFERENCE
    /// MediaOpener.open starts from, counted so the console can say it.
    /// It is intent, not a receipt: the opener still skips unreachable
    /// files and, in remote-viewer mode, routes streams to VLC (codex
    /// 2026-09-26 F1) — its own log lines say what actually launched.
    /// Cheap: three string compares per record, only for the rows opened.
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
        if qt > 0 { parts.append("\(qt) for QuickTime Player") }
        if vlc > 0 { parts.append("\(vlc) for VLC") }
        if other > 0 { parts.append("\(other) for the default app") }
        return parts.joined(separator: ", ")
    }
}
