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
// what the launch (or a running Switch) decided.
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

    /// Switch Catalog to SQLite… froze catalog.json while it decides the latch.
    var switchFreeze = false

    /// CatalogStore.isReadOnly — may catalog.json be written?
    var storeReadOnly: Bool { jsonFrozenByLaunch || viewerRole || switchFreeze }

    /// VideoScanModel.isReadOnly — may the session edit (the UI half)?
    var modelReadOnly: Bool { sessionReadOnlyByLaunch || viewerRole || switchFreeze }
}
