// PersonNameGuard.swift
// One rule for every operation that is still keyed by a person's SHORT
// name after folders became uuid-keyed (2026-09-12): holdout review
// queues, validation labels, catalog writeback, quick-save by name.
//
// Two people may share a short name (Richard Jr = Rick, Richard Sr = Dad).
// A name-keyed write for such a name cannot know which person it is about,
// so it is REFUSED at the write sink itself — not only at the button that
// opens the sheet — with a sentence that says what to change. codex review
// of c56bd2bc: an already-open sheet, or a namesake created after the sheet
// opened, must hit the same wall.
//
// C++ readers: a namespace of static functions plus one injectable
// "roster" closure (≈ a function pointer with a default) so tests can hand
// in a synthetic gallery without touching the per-process store.

import Foundation

enum PersonNameGuard {

    /// The refusal, as an error a throwing write path can surface.
    struct Refused: LocalizedError, Equatable {
        let name: String
        let operation: String
        var errorDescription: String? { PersonNameGuard.refusal(name: name, operation: operation) }
    }

    /// The saved profiles the guard checks against. Default: the gallery on
    /// disk. `nonisolated(unsafe)` ≈ a plain global — tests replace it for
    /// the duration of a test; production never touches it.
    nonisolated(unsafe) static var roster: () -> [POIProfile] = { POIProfile.listAll() }

    /// True when more than one profile in `profiles` has this canonical
    /// short name (case-insensitive).
    static func isShared(_ name: String, among profiles: [POIProfile]) -> Bool {
        let key = name.lowercased()
        return profiles.filter { $0.name.lowercased() == key }.count > 1
    }

    /// True when the GALLERY holds two or more profiles with `profile`'s
    /// canonical short name. A profile that is not (yet) in the gallery —
    /// a scan fixture, a seam — is judged by the gallery alone: one saved
    /// namesake is the same person as far as name-keyed rows can tell.
    static func isShared(_ profile: POIProfile, among profiles: [POIProfile]) -> Bool {
        isShared(profile.name, among: profiles)
    }

    /// Throws `Refused` when `name` is shared in the roster. Call this at
    /// the write sink, before any file is opened.
    static func check(_ name: String, operation: String) throws {
        if isShared(name, among: roster()) {
            throw Refused(name: name, operation: operation)
        }
    }

    /// The sentence a refused name-keyed operation shows.
    static func refusal(name: String, operation: String) -> String {
        "Two people are called \(name) — \(operation) is keyed by the short name. Give one of them a distinct short name first (aliases are what the cards show)."
    }

    /// What a catalog tag writeback may do for `identity`, decided AT THE
    /// SINK against the roster as it is NOW (codex post-merge review
    /// 2026-09-13, People #2 — the scan-start guard cannot see a namesake
    /// created mid-scan, a person deleted mid-scan, or a cache restore).
    enum CatalogWriteResolution: Equatable {
        /// Tag with this canonical name (the bound uuid's current name).
        case write(name: String)
        /// Tag nothing; the reason, for the log.
        case refused(String)
    }

    /// A bound uuid must still resolve, and its CURRENT canonical name
    /// must be unique in the roster; a name without a uuid must be unique.
    static func resolveForCatalogWrite(_ identity: PersonTagIdentity,
                                       among profiles: [POIProfile]) -> CatalogWriteResolution {
        if let uuid = identity.uuid {
            guard let profile = profiles.first(where: { $0.uuid == uuid }) else {
                return .refused("The person this search was about (\(identity.name), \(uuid.uuidString)) is no longer in the gallery — the catalog was not tagged. Pick who you mean and search again.")
            }
            if isShared(profile.name, among: profiles) {
                return .refused(refusal(name: profile.name, operation: "tagging the catalog"))
            }
            return .write(name: profile.name)
        }
        if isShared(identity.name, among: profiles) {
            return .refused(refusal(name: identity.name, operation: "tagging the catalog"))
        }
        return .write(name: identity.name)
    }
}

/// Who a catalog tag writeback is about. The uuid is the identity; the
/// name is what the scan was keyed by (`ScanJob.personLabel`). `uuid` is
/// nil only for a profile whose uuid was never persisted (a quarantined
/// legacy folder — `POIProfile.uuidPersisted == false`): such a person is
/// still identified by name, and only while that name is unique.
/// (C++ readers: a two-field POD handed from the scan to the write sink.)
struct PersonTagIdentity: Equatable, Sendable {
    var name: String
    var uuid: UUID?

    init(name: String, uuid: UUID? = nil) {
        self.name = name
        self.uuid = uuid
    }

    init(profile: POIProfile) {
        self.init(name: profile.name, uuid: profile.uuidPersisted ? profile.uuid : nil)
    }
}
