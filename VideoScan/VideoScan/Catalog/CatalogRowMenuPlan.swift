// CatalogRowMenuPlan.swift
// The DECISIONS behind the Catalog row context menu, as plain data (R1
// refactor, GH #281; the "explicit action plans" direction of the
// 2026-09-13 refactoring assessment §4). No SwiftUI, no model, no disk:
// every type here is unit-testable on its own (CatalogRowMenuPlanTests).
// The menu builders in CatalogRowContextMenu*.swift read these values;
// what they build is unchanged.

import Foundation

/// A right-click selection split by lifecycle state, and which of the
/// four menus it gets. O(selection), computed once per menu open so the
/// Restore / Remove items' labels count exactly the rows their actions
/// operate on. (C++: a small struct of vectors filled in the constructor
/// — Swift's `.filter` ≈ std::copy_if into a new vector.)
struct CatalogRowMenuSelection {

    /// Which right-click menu the selection gets.
    enum Shape: Equatable {
        /// Pure removed selection: Restore + Reveal.
        case purged
        /// Pure set-aside selection: Put Back + Reveal.
        case setAside
        /// Pure superseded selection: Show Repaired Copy + Restore + Reveal (GH #132).
        case superseded
        /// Active or mixed selection: the full menu.
        case full
    }

    /// The selected records, in selection order.
    let selected: [VideoRecord]
    /// Neither removed, set aside nor superseded.
    let active: [VideoRecord]
    let purged: [VideoRecord]
    /// Set aside and NOT removed (a removed row counts as removed only).
    let setAside: [VideoRecord]
    /// Superseded and neither removed nor set aside.
    let superseded: [VideoRecord]

    init(selected: [VideoRecord]) {
        self.selected = selected
        active = selected.filter { !$0.isPurged && !$0.isSetAside && !$0.isSuperseded }
        purged = selected.filter { $0.isPurged }
        setAside = selected.filter { $0.isSetAside && !$0.isPurged }
        superseded = selected.filter { $0.isSuperseded && !$0.isPurged && !$0.isSetAside }
    }

    /// No inert row rode along. Active-only actions (Combine, Rename,
    /// Tag, …) are gated on this so a multi-select that pulled in a
    /// removed / set-aside / superseded row never applies them to it.
    var pureActive: Bool {
        purged.isEmpty && setAside.isEmpty && superseded.isEmpty
    }

    /// The menu for a right-click whose anchor row is `anchor` (the row
    /// the table reports first). nil = no menu items at all.
    func shape(anchor: VideoRecord) -> Shape? {
        guard !active.isEmpty || anchor.isPurged || anchor.isSetAside || anchor.isSuperseded else {
            return nil
        }
        if anchor.isPurged && active.isEmpty { return .purged }
        if anchor.isSetAside && active.isEmpty { return .setAside }
        if anchor.isSuperseded && active.isEmpty { return .superseded }
        return .full
    }
}

/// The row menu's count-bearing labels and its alert wording, as pure
/// functions of the counts the items act on. One function per item, so
/// a label cannot count a different set than its action. (A Swift
/// caseless `enum` ≈ a C++ namespace of free functions.)
enum CatalogRowMenuText {
    static func analyze(count: Int) -> String {
        count > 1 ? "Analyze \(count) Files" : "Analyze"
    }
    static func removeFromCatalog(count: Int) -> String {
        count > 1 ? "Remove \(count) from Catalog" : "Remove from Catalog"
    }
    static func deleteFiles(count: Int) -> String {
        count > 1 ? "Delete \(count) Files" : "Delete File"
    }
    /// Shared by the removed-rows menu and a mixed selection's item.
    static func restoreToCatalog(count: Int) -> String {
        count > 1 ? "Restore \(count) to Catalog" : "Restore to Catalog"
    }
    /// Shared by the set-aside menu and a mixed selection's item.
    static func putBackInCatalog(count: Int) -> String {
        count > 1 ? "Put \(count) Back in Catalog" : "Put Back in Catalog"
    }
    /// Shared by the superseded menu and a mixed selection's item.
    static func restoreOriginals(count: Int) -> String {
        count > 1 ? "Restore \(count) Originals (Un-supersede)" : "Restore Original (Un-supersede)"
    }
    static func repairDamagedAudio(count: Int) -> String {
        count > 1 ? "Repair Damaged Audio (\(count) Files)" : "Repair Damaged Audio"
    }
    static func confirmRepairs(count: Int) -> String {
        count > 1 ? "Sounds Good — Confirm \(count) Repairs" : "Sounds Good — Confirm Repair"
    }
    /// Delete Permanently… confirmation title. `firstFilename` is used
    /// only when exactly one file is going.
    static func permanentDeleteQuestion(count: Int, firstFilename: String) -> String {
        count == 1
            ? "Delete \u{201C}\(firstFilename)\u{201D} permanently?"
            : "Delete \(count) files permanently?"
    }
    static func permanentDeleteWarning(count: Int) -> String {
        "This cannot be undone \u{2014} the file\(count == 1 ? " is" : "s are") removed from disk immediately, not moved to Trash."
    }
}

/// The row menu's enable / show rules that need no SwiftUI. Each takes
/// the facts it decides on (reachability, a running job) as plain values,
/// so the tests need no volume and no job center. O(1) or O(selection).
enum CatalogRowMenuRules {
    /// Transcode ▸ items grey out offline or while this record transcodes.
    static func transcodeBlocked(reachable: Bool, running: Bool) -> Bool {
        !reachable || running
    }
    /// Clean Up Video ▸ items need a picture, an online volume and no
    /// cleanup already running for this record (CleanupScaleTests pins
    /// that the inputs stay O(1) per record).
    static func cleanupBlocked(reachable: Bool, running: Bool, streamType: StreamType) -> Bool {
        !reachable
            || running
            || !(streamType == .videoAndAudio || streamType == .videoOnly)
    }
    /// Transcribe Audio is greyed (not hidden) without an audio stream.
    static func hasAudio(_ streamType: StreamType) -> Bool {
        streamType == .videoAndAudio || streamType == .audioOnly
    }
    /// Rows Mark as Family Music… may mark: anything with a stream.
    static func familyMusicMarkable(_ active: [VideoRecord]) -> [VideoRecord] {
        active.filter { $0.streamType != .noStreams && $0.streamType != .ffprobeFailed }
    }
    /// Rows Unmark acts on (the item shows only when this is non-empty).
    static func familyMusicMarked(_ active: [VideoRecord]) -> [VideoRecord] {
        active.filter { $0.familyMusic != nil }
    }
    /// Rows Repair Damaged Audio acts on: the verifiable rows Verify
    /// Audio called damaged.
    static func damagedAudio(_ verifiable: [VideoRecord]) -> [VideoRecord] {
        verifiable.filter { $0.audioVerifyStatus == "damaged" }
    }
}
