// TreeIdentityShowInTree.swift
// The pure half of right-click People → person → "Show in Family Tree"
// (Rick, 2026-08-29: "if ambiguous … say 'ID is this xxx' and if it is
// wrong, it asks for the right one, if it is missing it says 'using ID for
// Rick, OK'"). Two pieces, both free of UI and disk:
//
//   • `ShowInTreeReducer.state(…)` — the state machine: given the profile,
//     its neighbours, the installed tree and the deriver's verdict, which of
//     the six things the tab should do (focus / announce / ask / search /
//     "not in the tree" / legacy name focus).
//   • `TreeIdentityPinning` — the writes: pin, unpin, mark-not-in-tree, each
//     through an injected `store` closure (production: profile.save()),
//     refusing a pin that collides with another profile's, and mirroring
//     the owner's pin into Hallie's `hallie.ownerFamilySearchID` through an
//     injected UserDefaults.
//
// C++ readers: `(POIProfile) throws -> Void` is a std::function that may
// throw; `UserDefaults?` nil means "no mirror" (tests), never .standard by
// accident.

import Foundation
import VideoScanCore

enum ShowInTreeState: Equatable, Sendable {
    /// No tree installed (or still loading): fall back to the name hint.
    case noTree
    /// A usable pin — focus it and show the identity banner.
    case pinned(TreeIdentityCandidate)
    /// A pin that does not bridge (stale, unreadable, colliding): ask again,
    /// with the reason.
    case pinProblem(String)
    /// Rick said this person is not on the tree.
    case notInTree
    /// Derivable now; persist it, announce "Using … — OK" with an Undo.
    case derived(TreeIdentityCandidate, reason: TreeIdentityDerivation.Reason)
    /// Several records could be them: the which-one sheet.
    case ambiguous([TreeIdentityCandidate])
    /// Nothing on the tree: the search-or-not-in-tree sheet.
    case none
}

enum ShowInTreeReducer {

    /// `fingerprint` is the installed tree's content fingerprint when known
    /// (needed only to honour export-local pointer pins). `derivation` is the
    /// deriver's verdict for an UNPINNED profile, nil when it was not run.
    static func state(
        profile: POIProfile,
        profiles: [POIProfile],
        graph: GedcomFamilyGraph?,
        fingerprint: String?,
        derivation: TreeIdentityDerivation?
    ) -> ShowInTreeState {
        guard let graph else { return .noTree }
        if profile.treeIdentityQuarantined != nil {
            return .pinProblem("\(profile.name)'s family-tree pin could not be read (written by a newer app version?) — pick them again.")
        }
        if let pin = profile.treeIdentity {
            guard let person = TreeIdentityDeriver.pinnedPerson(pin, graph: graph, fingerprint: fingerprint) else {
                return .pinProblem("\(profile.name)'s family-tree pin points at a person this tree doesn't carry — pick them again.")
            }
            if let other = profiles.first(where: { $0.id != profile.id && $0.treeIdentity == pin }) {
                return .pinProblem("\(profile.name) and \(other.name) are both pinned to \(person.name) — only one profile can be that person.")
            }
            return .pinned(TreeIdentityCandidate(person))
        }
        if profile.notInFamilyTree { return .notInTree }
        switch derivation {
        case .certain(let candidate, let reason)?: return .derived(candidate, reason: reason)
        case .ambiguous(let candidates)?:          return .ambiguous(candidates)
        case TreeIdentityDerivation.none?, nil:    return .none
        }
    }

    /// "Rick is Richard Harding Breen Jr (b. 1959) · GVQV-NW3"
    static func pinnedLine(profileName: String, candidate: TreeIdentityCandidate) -> String {
        "\(profileName) is \(candidate.label) · \(candidate.code)"
    }

    /// "Using Richard Harding Breen Jr (GVQV-NW3) for Rick"
    static func usingLine(profileName: String, candidate: TreeIdentityCandidate) -> String {
        "Using \(candidate.name) (\(candidate.code)) for \(profileName)"
    }
}

enum TreeIdentityPinning {

    enum Outcome: Equatable {
        case saved(POIProfile)
        case refused(String)

        var profile: POIProfile? {
            if case .saved(let p) = self { return p }
            return nil
        }
        var refusal: String? {
            if case .refused(let why) = self { return why }
            return nil
        }
    }

    /// Pin `profile` to `candidate`. Refused (nothing written) when another
    /// profile already carries the same pin. On success the saved profile
    /// is returned and — when the profile is spelled like Hallie's owner
    /// and the record has a FamilySearch ID — the owner setting is mirrored
    /// so Hallie's "me" and the People tab's Rick can never disagree.
    static func pin(
        _ candidate: TreeIdentityCandidate,
        on profile: POIProfile,
        among profiles: [POIProfile],
        fingerprint: String?,
        attestation: String,
        ownerName: String?,
        store: (POIProfile) throws -> Void,
        defaults: UserDefaults?
    ) -> Outcome {
        let identity = candidate.identity(fingerprint: fingerprint)
        if let other = profiles.first(where: { $0.id != profile.id && $0.treeIdentity == identity }) {
            return .refused("\(other.name) is already pinned to \(candidate.name) (\(candidate.code)) — only one profile can be that person. Change \(other.name)'s pin first.")
        }
        var updated = profile
        updated.treeIdentity = identity
        updated.treeIdentityQuarantined = nil
        updated.treeIdentityAttestation = attestation
        updated.notInFamilyTree = false
        do { try store(updated) } catch {
            return .refused("Could not save \(profile.name)'s pin: \(error.localizedDescription)")
        }
        appLog.write("[people] pinned \(profile.name) → \(candidate.code) (\(attestation.replacingOccurrences(of: "derived: ", with: "")))")
        mirrorOwner(profile: profile, familySearchID: candidate.familySearchID,
                    ownerName: ownerName, defaults: defaults)
        return .saved(updated)
    }

    /// Remove the pin (the Undo behind "Using … — OK"). The owner setting
    /// is NOT cleared: it is Hallie's own configuration and may be the
    /// source the pin was derived from.
    static func unpin(
        _ profile: POIProfile,
        store: (POIProfile) throws -> Void
    ) -> Outcome {
        var updated = profile
        updated.treeIdentity = nil
        updated.treeIdentityAttestation = nil
        do { try store(updated) } catch {
            return .refused("Could not save \(profile.name): \(error.localizedDescription)")
        }
        appLog.write("[people] unpinned \(profile.name) (undo)")
        return .saved(updated)
    }

    /// "Not in the tree": stop asking for this person.
    static func markNotInTree(
        _ profile: POIProfile,
        store: (POIProfile) throws -> Void
    ) -> Outcome {
        var updated = profile
        updated.treeIdentity = nil
        updated.treeIdentityAttestation = nil
        updated.notInFamilyTree = true
        do { try store(updated) } catch {
            return .refused("Could not save \(profile.name): \(error.localizedDescription)")
        }
        appLog.write("[people] \(profile.name) marked not in the family tree")
        return .saved(updated)
    }

    /// Write the owner's FamilySearch ID into Hallie's setting when the
    /// pinned profile is the owner and the value differs. A nil `defaults`
    /// (tests without a suite) mirrors nothing.
    private static func mirrorOwner(profile: POIProfile, familySearchID: String?,
                                    ownerName: String?, defaults: UserDefaults?) {
        guard let defaults, let familySearchID,
              TreeIdentityDeriver.isOwnerSubject(TreeIdentitySubject(profile), ownerName: ownerName)
        else { return }
        let key = HallieTurnExecutor.Speakers.ownerFamilySearchIDDefaultsKey
        let current = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        guard current != familySearchID else { return }
        defaults.set(familySearchID, forKey: key)
        appLog.write("[people] owner FamilySearch ID \(current.isEmpty ? "set" : "changed from \(current)") to \(familySearchID) (mirrored from \(profile.name)'s pin)")
    }
}
