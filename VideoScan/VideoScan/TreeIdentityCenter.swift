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
//   • `treeLinkBadges(for:)` memoises the per-card tree-link badge map
//     (TreeLinkBadge) so the gallery never runs the reducer per render.
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

        /// The sentence without the code (the banner's first line; the code
        /// gets its own line — 2026-08-29 layout fix).
        var headline: String {
            switch kind {
            case .pinned: return ShowInTreeReducer.pinnedHeadline(profileName: profileName, candidate: candidate)
            case .using:  return ShowInTreeReducer.usingHeadline(profileName: profileName, candidate: candidate)
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
    /// Injectable async boundary for deterministic stale-pass tests. The
    /// production closure keeps the CPU work off the main actor.
    var derivationPass: (GedcomFamilyGraph, [TreeIdentitySubject], HallieTurnExecutor.Speakers) async
        -> [String: TreeIdentityDerivation] = { graph, subjects, speakers in
            await Task.detached(priority: .utility) {
                TreeIdentityDeriver(graph: graph, subjects: subjects,
                                    ownerName: speakers.ownerName,
                                    ownerFamilySearchID: speakers.ownerFamilySearchID).deriveAll()
            }.value
        }

    private var memoKey: MemoKey?
    private var inFlightKey: MemoKey?
    /// Logical generation of the accepted refresh. Unlike cancelling a
    /// Task, advancing this token also invalidates detached work that has
    /// already begun executing.
    private var refreshEpoch = 0
    /// Count of derivation passes actually run — tests pin the memo.
    private(set) var derivationRunCount = 0

    /// Exact inputs read by TreeIdentityDeriver. Keeping the value slice,
    /// rather than only a process-random hash, makes cache acceptance
    /// collision-free and lets consumers prove a verdict is current.
    struct DerivationSignature: Equatable {
        let subjects: [TreeIdentitySubject]
        let ownerName: String?
        let ownerFamilySearchID: String?
    }

    struct MemoKey: Equatable {
        let generation: Int
        let signature: DerivationSignature
    }

    private struct DerivationInput {
        let key: MemoKey
        let subjects: [TreeIdentitySubject]
        let speakers: HallieTurnExecutor.Speakers
    }

    init(kinshipCenter: KinshipDisplayCenter) {
        self.kinshipCenter = kinshipCenter
    }

    // MARK: Derivation pass

    private func derivationInput(for profiles: [POIProfile]) -> DerivationInput {
        let currentSpeakers = speakers()
        let subjects = profiles.map(TreeIdentitySubject.init)
        let signature = DerivationSignature(
            subjects: subjects,
            ownerName: currentSpeakers.ownerName,
            ownerFamilySearchID: currentSpeakers.ownerFamilySearchID
        )
        return DerivationInput(
            key: MemoKey(generation: kinshipCenter.graphGeneration, signature: signature),
            subjects: subjects,
            speakers: currentSpeakers
        )
    }

    /// The memo key for the People tab's `.task(id:)`.
    func refreshKey(for profiles: [POIProfile]) -> MemoKey {
        derivationInput(for: profiles).key
    }

    /// Derive proposals for every unpinned profile (off main), then
    /// auto-accept the trusted ones. Returns the profiles as they stand
    /// after any auto-pins (the caller reloads from disk anyway on
    /// `pinsRevision`). A pass for a key already memoised or in flight is
    /// a no-op.
    func refresh(profiles: [POIProfile]) async {
        guard let graph = kinshipCenter.graph else {
            refreshEpoch &+= 1
            inFlightKey = nil
            derivations = [:]
            memoKey = nil
            return
        }
        let input = derivationInput(for: profiles)
        let key = input.key
        // A → B → A: returning to the accepted A memo must logically
        // cancel a different B pass. Otherwise B can land later and
        // overwrite A even though this refresh was a memo hit.
        if key == memoKey {
            if inFlightKey != nil {
                refreshEpoch &+= 1
                inFlightKey = nil
            }
            return
        }
        guard key != inFlightKey else { return }
        refreshEpoch &+= 1
        let epoch = refreshEpoch
        inFlightKey = key
        let verdicts = await derivationPass(graph, input.subjects, input.speakers)
        // A graph clear/replacement or newer profile pass supersedes this
        // one while it is off actor. Detached work ignores parent Task
        // cancellation, so acceptance must be guarded explicitly.
        guard !Task.isCancelled,
              refreshEpoch == epoch,
              inFlightKey == key,
              derivationInput(for: profiles).key == key else {
            if inFlightKey == key { inFlightKey = nil }
            return
        }
        inFlightKey = nil
        derivationRunCount += 1
        derivations = verdicts
        memoKey = key
        if autoAcceptsTrustedSources {
            autoAccept(profiles: profiles, speakers: input.speakers)
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
        guard let currentProfile = profiles.first(where: { $0.id == profile.id }) else {
            let fingerprint: String? = {
                if case .pointer? = profile.treeIdentity { return kinshipCenter.graphFingerprint }
                return nil
            }()
            return ShowInTreeReducer.state(
                profile: profile,
                profiles: profiles,
                graph: graph,
                fingerprint: fingerprint,
                derivation: nil
            )
        }
        guard TreeIdentitySubject(currentProfile) == TreeIdentitySubject(profile) else {
            return .none
        }
        let input = derivationInput(for: profiles)
        var verdict = memoKey == input.key ? derivations[profile.id] : nil
        if verdict == nil, profile.treeIdentity == nil, profile.treeIdentityQuarantined == nil,
           !profile.notInFamilyTree {
            verdict = TreeIdentityDeriver(graph: graph, subjects: input.subjects,
                                          ownerName: input.speakers.ownerName,
                                          ownerFamilySearchID: input.speakers.ownerFamilySearchID)
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

    // MARK: Tree-link badges (People-tab cards)

    /// Memo key for the per-profile badge map: every input the reducer
    /// reads. `derivationRunCount` stands in for "the derivations dict
    /// changed"; `pinsRevision` for the writes.
    struct BadgeMemoKey: Equatable {
        let refreshKey: MemoKey
        let pinsRevision: Int
        let derivationRunCount: Int
    }

    private var badgeMemo: (key: BadgeMemoKey, map: [String: TreeLinkBadge])?
    /// Count of badge-map builds — tests pin the memo and its invalidation.
    private(set) var badgeComputeCount = 0

    /// Badge per profile id for the People gallery. Built once per
    /// (tree generation, identity signature, pinsRevision, derivation pass)
    /// and handed back on every render after that, so a card is one
    /// dictionary lookup — never per-card reducer work. Unpinned profiles
    /// the derivation pass has not covered get no badge until it lands
    /// (the `.task(id:)` in the gallery re-derives; no synchronous derive
    /// here, unlike `showInTreeState(for:)`).
    /// Memory: one small struct per profile — a few KB for a family.
    func treeLinkBadges(for profiles: [POIProfile]) -> [String: TreeLinkBadge] {
        let input = derivationInput(for: profiles)
        let key = BadgeMemoKey(refreshKey: input.key,
                               pinsRevision: pinsRevision,
                               derivationRunCount: derivationRunCount)
        if let badgeMemo, badgeMemo.key == key { return badgeMemo.map }
        guard let graph = kinshipCenter.graph else {
            badgeMemo = (key, [:])
            badgeComputeCount += 1
            return [:]
        }
        let fingerprint = kinshipCenter.graphFingerprint
        let currentDerivations = memoKey == input.key ? derivations : [:]
        var map: [String: TreeLinkBadge] = [:]
        map.reserveCapacity(profiles.count)
        for profile in profiles {
            let pointerFingerprint: String? = {
                if case .pointer? = profile.treeIdentity { return fingerprint }
                return nil
            }()
            let state = ShowInTreeReducer.state(profile: profile, profiles: profiles, graph: graph,
                                                fingerprint: pointerFingerprint,
                                                derivation: currentDerivations[profile.id])
            if let badge = TreeLinkBadge.state(for: state, profile: profile) {
                map[profile.id] = badge
            }
        }
        badgeMemo = (key, map)
        badgeComputeCount += 1
        return map
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
        guard let graph = kinshipCenter.graph else {
            return .refused("The family tree changed. Reopen this person and choose again.")
        }
        guard let currentProfile = profiles.first(where: { $0.id == profile.id }),
              TreeIdentitySubject(currentProfile) == TreeIdentitySubject(profile) else {
            return .refused("This person changed. Reopen them and choose the tree record again.")
        }
        let installedPerson: GedcomFamilyGraph.Person? = {
            if let familySearchID = candidate.familySearchID {
                return graph.person(familySearchID: familySearchID)
            }
            return graph.people[candidate.personID]
        }()
        guard let installedPerson,
              TreeIdentityCandidate(installedPerson) == candidate else {
            return .refused("The family tree changed. Reopen this person and choose again.")
        }
        // A derived suggestion is an action token, not a durable picker
        // choice. Re-derive it from the exact current inputs before writing
        // so a profile/speaker/tree change between display and click fails
        // closed even when the old record still exists in the new tree.
        if attestation.hasPrefix("derived:") {
            let input = derivationInput(for: profiles)
            let currentVerdict = TreeIdentityDeriver(
                graph: graph,
                subjects: input.subjects,
                ownerName: input.speakers.ownerName,
                ownerFamilySearchID: input.speakers.ownerFamilySearchID
            ).derive(TreeIdentitySubject(currentProfile))
            guard case .certain(let currentCandidate, _) = currentVerdict,
                  currentCandidate == candidate else {
                return .refused("The identity suggestion changed. Reopen this person and try again.")
            }
        }
        let outcome = TreeIdentityPinning.pin(
            candidate, on: currentProfile, among: profiles,
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
