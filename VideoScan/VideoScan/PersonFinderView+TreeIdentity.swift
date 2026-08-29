// PersonFinderView+TreeIdentity.swift
// Right-click People → person → "Show in Family Tree" (2026-08-29). The
// verdict comes from TreeIdentityCenter's pure state machine; this file only
// turns it into navigation, a banner, or the which-one sheet:
//
//   pinned      → focus that record; banner "Rick is … · GVQV-NW3 — Not right?"
//   derived     → pin it now (attested), focus; banner "Using … for Rick — OK / Undo"
//   ambiguous   → which-one sheet (pick → pin + focus)
//   none        → the same sheet in search mode, with "not in the tree"
//   notInTree   → the sheet offering to change that
//   pinProblem  → the sheet with the reason on top
//   noTree      → the pre-2026-08-29 name hint (the tree tab resolves by name)
//
// (Swift extension ≈ C++ partial class: no new stored state — the sheet
// target and the AppStorage hints live in PersonFinderView.swift.)

import SwiftUI

extension PersonFinderView {

    func showInFamilyTree(_ profile: POIProfile) {
        let profiles = model.savedProfiles
        switch identityCenter.showInTreeState(for: profile, among: profiles) {
        case .noTree:
            ftHighlightID = ""
            ftHighlight = profile.name
            selectedTab = 5
        case .pinned(let candidate):
            focusFamilyTree(profileName: profile.name, candidate: candidate, banner: .pinned)
        case .derived(let candidate, let reason):
            switch identityCenter.pin(candidate, on: profile, among: profiles,
                                      attestation: reason.attestation + " (Show in Family Tree)") {
            case .saved:
                focusFamilyTree(profileName: profile.name, candidate: candidate, banner: .using)
            case .refused(let why):
                identityPickTarget = TreeIdentityPickTarget(
                    profile: profile, candidates: [candidate], mode: .pinProblem(why), current: nil)
            }
        case .ambiguous(let candidates):
            identityPickTarget = TreeIdentityPickTarget(
                profile: profile, candidates: candidates, mode: .ambiguous, current: nil)
        case .none:
            identityPickTarget = TreeIdentityPickTarget(
                profile: profile, candidates: [], mode: .notFound, current: nil)
        case .notInTree:
            identityPickTarget = TreeIdentityPickTarget(
                profile: profile, candidates: [], mode: .notInTree, current: nil)
        case .pinProblem(let why):
            identityPickTarget = TreeIdentityPickTarget(
                profile: profile, candidates: [], mode: .pinProblem(why), current: nil)
        }
    }

    /// Drop the exact record into the tree tab's hint (the name rides along
    /// as the display name for an honest miss after a re-export), set the
    /// identity banner, and switch tabs.
    func focusFamilyTree(profileName: String, candidate: TreeIdentityCandidate,
                         banner: TreeIdentityCenter.Banner.Kind) {
        identityCenter.showBanner(banner, profileName: profileName, candidate: candidate)
        ftHighlight = profileName
        ftHighlightID = candidate.personID
        selectedTab = 5
    }
}
