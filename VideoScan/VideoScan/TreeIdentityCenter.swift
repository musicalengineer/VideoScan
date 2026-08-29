// TreeIdentityCenter.swift
// UI-side owner of the auto-derived profile → family-tree identity
// (2026-08-29, Rick: "let the computer melt silicon, not the user").
//
//   • On every People-tab appearance the unpinned profiles are run through
//     TreeIdentityDeriver OFF the main actor, memoised per (tree generation,
//     identity-relevant profile signature) — a notes edit or a re-render
//     never re-derives. Verdicts that are certain for the two trusted
//     sources (owner setting, tree root) are persisted at once with an
//     attestation; everything else waits for "Show in Family Tree".
//   • "Show in Family Tree" asks `showInTreeState(for:)`, and the pin /
//     unpin / not-in-tree writes go through here so the People gallery and
//     the Family Tree tab agree on one `pinsRevision`.
//   • The one-line identity banner the Family Tree tab shows after a focus
//     ("Rick is Richard Harding Breen Jr … — Not right?") lives here too, so
//     the People tab can set it and the tree tab can render it.
//
// Reads the tree from KinshipDisplayCenter (the People tab's tree source),
// writes profiles through an injectable `store` (production: save()), and
// mirrors the owner pin through an injectable `defaults`. Tests build an
// isolated center with an isolated KinshipDisplayCenter, a capturing store
// and a throwaway UserDefaults suite.
//
// `@MainActor` ≈ "this must run on the UI thread"; `Task.detached` ≈ hand
// a value copy to a worker thread and come back with the result.

import Foundation
import Combine
import VideoScanCore

@MainActor
final class TreeIdentityCenter: ObservableObject {
    static let shared = TreeIdentityCenter(kinshipCenter: .shared)

    /// The Family Tree tab's identity line after a People-tab focus.
    struct Banner: Equatable {
        enum Kind: Equatable {
            /// "Rick is Richard Harding Breen Jr (b. 1959) · GVQV-NW3 — Not right?"
            case pinned
            /// "Using Richard Harding Breen Jr (GVQV-NW3) for Rick — OK / Undo"
            case using
        }
        let kind: Kind
        let profileName: String
        let candidate: TreeIdentityCandidate

        var line: String {
            switch kind {
            case .pinned: return ShowInTreeReducer.pinnedLine(profileName: profileName, candidate: candidate)
            case .using:  return ShowInTreeReducer.usingLine(profileName: profileName, candidate: candidate)
            }
        }
    }

    @Published private(set) var banner: Banner?
    /// Bumps on every pin / unpin / not-in-tree write, so the People gallery
    /// reloads its profiles and the tree tab's banner refreshes.
    @Published private(set) var pinsRevision = 0
    /// Verdicts for the current (generation, signature) — read by the
    /// gallery for the derived-identity hint and by "Show in Family Tree".
    @Published private(set) var derivations: [String: TreeIdentityDerivation] = [:]

    let kinshipCenter: KinshipDisplayCenter
    /// Injectable persistence + owner mirror + speaker source.
    var store: (POIProfile) throws -> Void = { try $0.save() }
    var defaults: UserDefaults? = .standard
    var speakers: () -> HallieTurnExecutor.Speakers = { .fromDefaults() }
    /// Auto-accepting owner/root verdicts can be switched off (tests that
    /// only want the proposals).
    var autoAcceptsTrustedSources = true

    private var memoKey: MemoKey?
    private var inFlightKey: MemoKey?
    /// Count of derivation passes actually run — tests pin the memo.
    private(set) var derivationRunCount = 0

    struct MemoKey: Equatable {
        let generation: Int
        let signature: Int
    }

    init(kinshipCenter: KinshipDisplayCenter) {
        self.kinshipCenter = kinshipCenter
    }

    // MARK: Derivation pass

    /// Hash of every field the deriver reads — and nothing else.
    static func identitySignature(of profiles: [POIProfile]) -> Int {
        var hasher = Hasher()
        hasher.combine(profiles.count)
        for p in profiles {
            hasher.combine(p.name)
            hasher.combine(p.uuid)
            hasher.combine(p.aliases)
            hasher.combine(p.sex)
            hasher.combine(p.birthdate)
            hasher.combine(p.deathdate)
            hasher.combine(p.kinships)
            hasher.combine(p.treeIdentity)
            hasher.combine(p.treeIdentityQuarantined != nil)
            hasher.combine(p.notInFamilyTree)
        }
        return hasher.finalize()
    }

    /// The memo key for the People tab's `.task(id:)`.
    func refreshKey(for profiles: [POIProfile]) -> MemoKey {
        MemoKey(generation: kinshipCenter.graphGeneration, signature: Self.identitySignature(of: profiles))
    }

    /// Derive proposals for every unpinned profile (off main), then
    /// auto-accept the trusted ones. Returns the profiles as they stand
    /// after any auto-pins (the caller reloads from disk anyway on
    /// `pinsRevision`). A pass for a key already memoised or in flight is
    /// a no-op.
    func refresh(profiles: [POIProfile]) async {
        guard let graph = kinshipCenter.graph else {
            derivations = [:]
            memoKey = nil
            return
        }
        let key = refreshKey(for: profiles)
        guard key != memoKey, key != inFlightKey else { return }
        inFlightKey = key
        let speakers = speakers()
        let subjects = profiles.map(TreeIdentitySubject.init)
        let verdicts = await Task.detached(priority: .utility) { () -> [String: TreeIdentityDerivation] in
            TreeIdentityDeriver(graph: graph, subjects: subjects,
                                ownerName: speakers.ownerName,
                                ownerFamilySearchID: speakers.ownerFamilySearchID).deriveAll()
        }.value
        // A newer pass superseded this one while we were off the actor.
        guard inFlightKey == key else { return }
        inFlightKey = nil
        derivationRunCount += 1
        derivations = verdicts
        memoKey = key
        if autoAcceptsTrustedSources {
            autoAccept(profiles: profiles, speakers: speakers)
        }
    }

    /// Persist the `.certain` verdicts whose reason is a trusted identity
    /// source (owner setting, tree root). One record per profile; a
    /// collision is refused and logged, never forced.
    private func autoAccept(profiles: [POIProfile], speakers: HallieTurnExecutor.Speakers) {
        var current = profiles
        var pinnedAny = false
        for profile in profiles {
            guard profile.treeIdentity == nil, !profile.notInFamilyTree,
                  case .certain(let candidate, let reason)? = derivations[profile.id],
                  reason.isAutoAcceptable else { continue }
            switch TreeIdentityPinning.pin(
                candidate, on: profile, among: current,
                fingerprint: candidate.familySearchID == nil ? kinshipCenter.graphFingerprint : nil,
                attestation: reason.attestation, ownerName: speakers.ownerName,
                store: store, defaults: defaults) {
            case .saved(let saved):
                if let i = current.firstIndex(where: { $0.id == saved.id }) { current[i] = saved }
                derivations[profile.id] = nil
                pinnedAny = true
            case .refused(let why):
                appLog.write("[people] auto-pin of \(profile.name) refused: \(why)")
            }
        }
        if pinnedAny { pinsRevision += 1 }
    }

    // MARK: Show in Family Tree

    /// The state machine's verdict for one profile. The derivation comes
    /// from the memo; when the memo has not run for this profile (tree just
    /// arrived, profile just added) one profile is derived synchronously —
    /// a handful of indexed lookups, not a tree walk.
    func showInTreeState(for profile: POIProfile, among profiles: [POIProfile]) -> ShowInTreeState {
        guard let graph = kinshipCenter.graph else { return .noTree }
        var verdict = derivations[profile.id]
        if verdict == nil, profile.treeIdentity == nil, profile.treeIdentityQuarantined == nil,
           !profile.notInFamilyTree {
            let speakers = speakers()
            verdict = TreeIdentityDeriver(graph: graph, profiles: profiles,
                                          ownerName: speakers.ownerName,
                                          ownerFamilySearchID: speakers.ownerFamilySearchID)
                .derive(TreeIdentitySubject(profile))
        }
        let fingerprint: String? = {
            if case .pointer? = profile.treeIdentity { return kinshipCenter.graphFingerprint }
            return nil
        }()
        return ShowInTreeReducer.state(profile: profile, profiles: profiles, graph: graph,
                                       fingerprint: fingerprint,
                                       derivation: verdict)
    }

    /// Candidates behind a tree-picker search, for the which-one sheet's
    /// search field. Capped like the picker.
    func searchCandidates(_ typed: String, limit: Int = 25) -> [TreeIdentityCandidate] {
        guard let graph = kinshipCenter.graph else { return [] }
        return kinshipCenter.searchTreePeople(typed, limit: limit)
            .compactMap { graph.people[$0.pointer] }
            .map(TreeIdentityCandidate.init)
    }

    // MARK: Writes

    @discardableResult
    func pin(_ candidate: TreeIdentityCandidate, on profile: POIProfile, among profiles: [POIProfile],
             attestation: String) -> TreeIdentityPinning.Outcome {
        let outcome = TreeIdentityPinning.pin(
            candidate, on: profile, among: profiles,
            fingerprint: candidate.familySearchID == nil ? kinshipCenter.graphFingerprint : nil,
            attestation: attestation, ownerName: speakers().ownerName,
            store: store, defaults: defaults)
        if case .saved = outcome {
            derivations[profile.id] = nil
            pinsRevision += 1
        }
        return outcome
    }

    @discardableResult
    func unpin(_ profile: POIProfile) -> TreeIdentityPinning.Outcome {
        let outcome = TreeIdentityPinning.unpin(profile, store: store)
        if case .saved = outcome {
            memoKey = nil          // the next pass re-derives this profile
            pinsRevision += 1
        }
        return outcome
    }

    @discardableResult
    func markNotInTree(_ profile: POIProfile) -> TreeIdentityPinning.Outcome {
        let outcome = TreeIdentityPinning.markNotInTree(profile, store: store)
        if case .saved = outcome {
            derivations[profile.id] = nil
            pinsRevision += 1
        }
        return outcome
    }

    // MARK: Banner

    func showBanner(_ kind: Banner.Kind, profileName: String, candidate: TreeIdentityCandidate) {
        banner = Banner(kind: kind, profileName: profileName, candidate: candidate)
    }

    func dismissBanner() { banner = nil }
}

/// What the which-one sheet is for. `Identifiable` so `.sheet(item:)` can
/// present it (the item-binding form, per the chained-sheet note).
struct TreeIdentityPickTarget: Identifiable, Equatable {
    enum Mode: Equatable {
        /// Several records could be this person.
        case ambiguous
        /// Nothing matched: search, or mark "not in the tree".
        case notFound
        /// "Not right?" on an existing pin (preselected).
        case changePin
        /// A pin that does not bridge on this tree.
        case pinProblem(String)
        /// Already marked "not in the tree" — offer to change that.
        case notInTree
    }
    let profile: POIProfile
    let candidates: [TreeIdentityCandidate]
    let mode: Mode
    /// The current pin's record, preselected in `.changePin`.
    let current: TreeIdentityCandidate?
    var id: String { profile.id }
}
