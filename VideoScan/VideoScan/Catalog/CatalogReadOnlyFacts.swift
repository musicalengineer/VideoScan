// CatalogReadOnlyFacts.swift
// Why this session's catalog is read-only — one fact per owner, combined in
// ONE place (VideoScanModel.updateReadOnlyFacts).
//
// P0 2026-10-19: the window's onAppear applied the viewer/master role AFTER
// the launch had decided, by assigning both flags outright. On the master
// (role = writable) that undid a refused SQLite launch — catalog.json became
// writable with no committer, so the session's edits landed in a catalog the
// next good SQLite launch ignores (two writable catalogs) — and it lit up the
// edit controls of a read-only catalog.sqlite while every commit was refused.
//
// The rule now: each owner sets or clears only its OWN fact; the effective
// flags are the OR of the facts. So the role can add read-only, never remove
// what the launch decided. (The Switch's own freeze fact left with Switch
// Catalog to SQLite…, 2026-10-20.)
//
// C++ analogy: a value struct of bools with two const getters; the model
// holds one instance and is the only code that copies the getters into the
// two published flags.

import Foundation

struct CatalogReadOnlyFacts: Equatable, Sendable {

    /// The launch: catalog.json is frozen — catalog.sqlite is the authority,
    /// or the SQLite launch was refused and catalog.json is open read-only.
    var jsonFrozenByLaunch = false

    /// The launch: nothing can be saved this session — the SQLite launch was
    /// refused, or catalog.sqlite opened read-only. Cleared only by
    /// Catalog ▸ Adopt This SQLite Catalog… (the committer became writable).
    var sessionReadOnlyByLaunch = false

    /// The role: this Mac is a viewer (CatalogSync, via applyReadOnlyMode).
    var viewerRole = false

    /// GH #343: catalog.sqlite was restored from a backup this session. The
    /// records on screen are the catalog as it was before; nothing is saved
    /// until VideoScan is reopened. Never cleared (not even by Adopt, which
    /// this session refuses).
    var restoredFromBackup = false

    /// Codex #384 F3: Restore from Backup… is running — from the moment Rick
    /// confirms (after what is in memory was committed) until it restores
    /// or refuses. Transient: cleared on every refusal, replaced by
    /// `restoredFromBackup` on success. An edit made in this window would
    /// be in neither the safety copy nor the restored catalog.
    var restoringFromBackup = false

    /// GH #520 (Codex round 2, P1-5): Apply… of a quit rescue copy is
    /// running — from before its backup starts until it finishes or
    /// refuses. Transient. Pauses EDITING only (the UI via `isReadOnly`, the
    /// curated edit guard), NOT the committer: Apply's own backup commits
    /// what is in memory first and then commits the applied records, so this
    /// fact stays out of `readOnlyWords` (what the committer and the quit
    /// read). Anything else that commits meanwhile moves the generation, and
    /// Apply then refuses (the backup no longer undoes exactly what it does).
    var applyingRescueCopy = false

    /// The launch opened no catalog (no latch, GH #354; or catalog.sqlite
    /// refused): its words, for the doors that need a catalog (QA r1 F5).
    var launchRefusalWords: String?

    /// CatalogStore.isReadOnly — may catalog.json be written?
    var storeReadOnly: Bool { jsonFrozenByLaunch || viewerRole }

    /// VideoScanModel.isReadOnly — may the session edit (the UI half)?
    var modelReadOnly: Bool {
        sessionReadOnlyByLaunch || viewerRole || restoredFromBackup || restoringFromBackup || applyingRescueCopy
    }

    /// Why the session may not write, in the person's words — nil when it
    /// may. The SQLite committer refuses every commit while this is non-nil
    /// (codex cycle #112: the facts must reach the committer, not only the UI).
    var readOnlyWords: String? {
        if viewerRole { return "this Mac is a viewer — only the master writes the catalog" }
        if restoredFromBackup { return Self.restoredWords }
        if restoringFromBackup { return Self.restoringWords }
        if sessionReadOnlyByLaunch { return "the catalog opened read-only at launch" }
        return nil
    }

    /// Why an EDIT is refused now, in the person's words: `readOnlyWords`,
    /// or the transient pause while a rescue copy is applied. nil = editable.
    var editRefusalWords: String? {
        readOnlyWords ?? (applyingRescueCopy ? Self.applyingRescueWords : nil)
    }

    /// While Apply… of a quit rescue copy runs (GH #520, Codex round 2 P1-5).
    static let applyingRescueWords = "applying the rescue copy — editing is paused until it finishes"

    /// The read-only words after Restore from Backup… (GH #343).
    static let restoredWords = "the catalog was restored from a backup in this session — quit VideoScan and open it again to see it"

    /// While Restore from Backup… runs (codex #384 F3).
    static let restoringWords = "restoring the catalog — editing is paused until the restore finishes"
}
